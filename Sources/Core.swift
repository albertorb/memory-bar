import AppKit
import Darwin
import SwiftUI

// MARK: - System memory

struct SystemMemory {
    let total: UInt64
    let used: UInt64        // Activity Monitor "Memory Used" = app + wired + compressed
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let swapUsed: UInt64
    let pressure: Int32     // 1 normal, 2 warning, 4 critical

    static func read() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var pressure: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)

        return SystemMemory(total: ProcessInfo.processInfo.physicalMemory,
                            used: app + wired + compressed, app: app, wired: wired,
                            compressed: compressed, cached: cached,
                            swapUsed: swap.xsu_used, pressure: pressure)
    }
}

// MARK: - Processes grouped by app

struct ProcessEntry: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let memory: UInt64
    let path: String
    let command: String
}

struct ProcessGroup: Identifiable {
    var id: String { name }
    let name: String
    let bundlePath: String?     // nil for CLI tools and macOS services
    var memory: UInt64 = 0
    var processes: [ProcessEntry] = []
}

enum ProcessSampler {
    static let systemGroup = "Servicios de macOS"
    private static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]
    private static let terminalApps: Set<String> = ["Terminal", "iTerm", "iTerm2", "Ghostty", "WezTerm", "Warp",
                                                    "Alacritty", "kitty", "Hyper", "Tabby", "Rio"]
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nu", "login", "tmux", "screen", "sudo", "env"]
    static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "java", "bun", "deno", "perl", "php"]

    private struct Raw {
        let pid: pid_t, ppid: pid_t, rss: UInt64, path: String
        var command = ""
    }

    private static func run(_ format: String) -> [Substring] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")   // setuid root, so it sees every process
        task.arguments = ["-axww", "-o", format]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    private static func snapshot() -> [pid_t: Raw] {
        var procs: [pid_t: Raw] = [:]
        for line in run("pid=,ppid=,rss=,comm=") {
            let p = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard p.count == 4, let pid = pid_t(p[0]), let ppid = pid_t(p[1]), let rss = UInt64(p[2]) else { continue }
            procs[pid] = Raw(pid: pid, ppid: ppid, rss: rss * 1024, path: String(p[3]))
        }
        for line in run("pid=,command=") {
            let p = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if p.count == 2, let pid = pid_t(p[0]) { procs[pid]?.command = String(p[1]) }
        }
        return procs
    }

    /// Physical footprint, the metric Activity Monitor shows. Only readable for our own user's processes.
    private static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// Private libsystem call Activity Monitor relies on: maps an XPC service (e.g. WebKit) to the app that spawned it.
    private static let responsiblePid: ResponsibleFn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    /// Outermost .app bundle containing the executable: it owns all its helpers (Chrome renderers, Electron, VMs...).
    static func appBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func isSystem(_ path: String) -> Bool {
        !path.hasPrefix("/") || systemPrefixes.contains(where: path.hasPrefix)
    }

    /// Readable name for a non-app process. Interpreters are named after what they run:
    /// `node .../node_modules/openclaw/dist/index.js` -> openclaw, `python -m hermes_cli.main` -> hermes_cli.
    static func toolName(path: String, command: String) -> String {
        let binary = (path as NSString).lastPathComponent
        guard interpreters.contains(where: { binary == $0 || binary.hasPrefix($0 + ".") || binary.hasPrefix($0 + "3") }) else {
            return binary
        }
        let args = command.split(separator: " ").dropFirst().map(String.init)
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-m", i + 1 < args.count { return String(args[i + 1].split(separator: ".")[0]) }
            if arg.hasPrefix("-") { i += 1; continue }
            if let range = arg.range(of: "/node_modules/") {
                let parts = arg[range.upperBound...].split(separator: "/")
                if let first = parts.first {
                    return first.hasPrefix("@") && parts.count > 1 ? "\(first)/\(parts[1])" : String(first)
                }
            }
            let file = (arg as NSString).lastPathComponent
            return (file as NSString).deletingPathExtension.isEmpty ? binary : (file as NSString).deletingPathExtension
        }
        return binary
    }

    private static func bundleName(_ bundle: String) -> String {
        ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Attributes a process to the app that really owns it, walking up the parent chain:
    /// - inside an .app bundle -> that app;
    /// - launched by an app (not a terminal) -> that app;
    /// - launched from a terminal -> the command the user ran (claude, codex, python script...);
    /// - launched by a background tool (e.g. the OpenClaw gateway) -> that tool;
    /// - macOS daemons -> the app responsible for them (WebKit -> Safari/OpenClaw), else macOS services.
    private static func owner(_ pid: pid_t, _ procs: [pid_t: Raw]) -> (name: String, bundle: String?) {
        guard let me = procs[pid] else { return (systemGroup, nil) }
        if let bundle = appBundle(me.path) { return (bundleName(bundle), bundle) }

        var chain = [me]
        var current = me
        while current.ppid > 1, let parent = procs[current.ppid], chain.count < 64 {
            chain.append(parent)
            if let bundle = appBundle(parent.path) {
                let name = bundleName(bundle)
                guard terminalApps.contains(name) else { return (name, bundle) }
                // Below the terminal: the first non-shell process is what the user launched.
                let launched = chain.dropLast().reversed().first { !shells.contains(($0.path as NSString).lastPathComponent) }
                guard let launched else { return (name, bundle) }
                return (toolName(path: launched.path, command: launched.command), nil)
            }
            current = parent
        }

        let root = chain.last!
        if !isSystem(root.path) { return (toolName(path: root.path, command: root.command), nil) }
        if !isSystem(me.path) { return (toolName(path: me.path, command: me.command), nil) }
        if let responsible = responsiblePid?(pid), responsible > 0, responsible != pid,
           let path = procs[responsible]?.path, let bundle = appBundle(path) {
            return (bundleName(bundle), bundle)
        }
        return (systemGroup, nil)
    }

    /// Installed apps by lowercased name, so a background tool named like an app (openclaw) joins it.
    private static let installedApps: [String: String] = {
        var apps: [String: String] = [:]
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                apps[(item as NSString).deletingPathExtension.lowercased()] = dir + "/" + item
            }
        }
        return apps
    }()

    static func sample() -> [ProcessGroup] {
        let procs = snapshot()
        var groups: [String: ProcessGroup] = [:]
        for raw in procs.values {
            var (name, bundle) = owner(raw.pid, procs)
            if bundle == nil, name != systemGroup, let app = installedApps[name.lowercased()] {
                (name, bundle) = (bundleName(app), app)
            }
            let process = ProcessEntry(pid: raw.pid, memory: footprint(raw.pid) ?? raw.rss,
                                       path: raw.path, command: raw.command.isEmpty ? raw.path : raw.command)
            groups[name, default: ProcessGroup(name: name, bundlePath: bundle)].memory += process.memory
            groups[name]!.processes.append(process)
        }
        return groups.values.sorted { $0.memory > $1.memory }
    }
}

// MARK: - Icons

enum Icons {
    private static var cache: [String: NSImage] = [:]
    private static let size = NSSize(width: 16, height: 16)

    static func icon(for group: ProcessGroup) -> NSImage {
        let key = group.bundlePath ?? "symbol:" + group.name
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let bundle = group.bundlePath, hasOwnIcon(bundle) {
            image = NSWorkspace.shared.icon(forFile: bundle)
        } else {
            image = fallback(for: group)
        }
        image.size = size
        cache[key] = image
        return image
    }

    /// Bundles without an icon (loginwindow, NotificationCenter...) would render the blank generic app icon.
    static func hasOwnIcon(_ bundle: String) -> Bool {
        guard let info = Bundle(path: bundle)?.infoDictionary else { return false }
        return info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil
    }

    /// SF Symbol when the group has no app bundle (or its bundle has no usable icon).
    static func fallbackSymbol(for group: ProcessGroup) -> String {
        if group.name == ProcessSampler.systemGroup { return "apple.logo" }
        if let bundle = group.bundlePath {
            return bundle.hasPrefix("/System/") ? "gearshape" : "app"
        }
        let binaries = Set(group.processes.map { ($0.path as NSString).lastPathComponent })
        if binaries.contains(where: { b in ProcessSampler.interpreters.contains { b == $0 || b.hasPrefix($0) } }) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "terminal"
    }

    private static func fallback(for group: ProcessGroup) -> NSImage {
        let name = fallbackSymbol(for: group)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: group.name)
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: group.name)!
        image.isTemplate = true
        return image
    }
}

// MARK: - Formatting

func gb(_ bytes: UInt64) -> String {
    let value = Double(bytes) / 1_073_741_824
    if value >= 1 { return String(format: "%.1f GB", value).replacingOccurrences(of: ".", with: ",") }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

func pressureLabel(_ level: Int32) -> String {
    switch level {
    case 4: return "crítica"
    case 2: return "alta"
    default: return "normal"
    }
}

/// Short, readable label for a process inside a group: binary name, plus script for interpreters.
func processLabel(_ p: ProcessEntry) -> String {
    let binary = (p.path as NSString).lastPathComponent
    let interpreters = ["node", "python", "python3", "ruby", "java", "bun", "deno", "bash", "zsh", "sh"]
    var label = binary
    if interpreters.contains(where: { binary == $0 || binary.hasPrefix($0 + ".") || binary.hasPrefix("python3.") }) {
        let args = p.command.split(separator: " ").dropFirst().prefix(3).map { arg -> String in
            arg.hasPrefix("/") ? (String(arg) as NSString).lastPathComponent : String(arg)
        }
        if !args.isEmpty { label += " " + args.joined(separator: " ") }
    }
    if label.count > 60 { label = String(label.prefix(59)) + "…" }
    return label
}

