import AppKit
import Darwin
import SwiftUI

// MARK: - Usage colour

/// Neutral (white on a dark menu bar) up to 60%, then blends to orange at 80% and to red at 95%.
func usageColor(_ fraction: Double) -> NSColor {
    NSColor(name: nil) { appearance in
        var base = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            base = NSColor.labelColor.usingColorSpace(.sRGB) ?? .white
        }
        let orange = NSColor.systemOrange.usingColorSpace(.sRGB)!
        let red = NSColor.systemRed.usingColorSpace(.sRGB)!
        switch fraction {
        case ..<0.6: return base
        case ..<0.8: return base.blended(withFraction: (fraction - 0.6) / 0.2, of: orange) ?? orange
        case ..<0.95: return orange.blended(withFraction: (fraction - 0.8) / 0.15, of: red) ?? red
        default: return red
        }
    }
}

/// Rounded horizontal bar for the menu bar: grey track, filled by usage.
func statusBarImage(fraction: Double) -> NSImage {
    let image = NSImage(size: NSSize(width: 34, height: 14), flipped: false) { rect in
        let track = NSRect(x: 0.5, y: (rect.height - 8) / 2, width: rect.width - 1, height: 8)
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        let width = max(track.height, track.width * min(max(fraction, 0), 1))
        usageColor(fraction).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: width, height: track.height),
                     xRadius: 4, yRadius: 4).fill()
        return true
    }
    image.isTemplate = false
    return image
}

// MARK: - Closing processes

enum Closer {
    /// Signal 0 only checks permission: system and other users' processes are excluded.
    static func canClose(_ pid: pid_t) -> Bool { pid != getpid() && kill(pid, 0) == 0 }

    static func canClose(_ group: ProcessGroup) -> Bool {
        group.name != ProcessSampler.systemGroup && group.processes.contains { canClose($0.pid) }
    }

    static func close(_ pid: pid_t, force: Bool) {
        if !force, let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil {
            app.terminate()     // lets the app save and quit normally
        } else {
            kill(pid, force ? SIGKILL : SIGTERM)
        }
    }

    /// Quits the group's apps normally; other processes in the group get SIGTERM (SIGKILL when forced).
    static func close(_ group: ProcessGroup, force: Bool) {
        var handled = Set<pid_t>()
        if !force, let bundle = group.bundlePath {
            let apps = NSWorkspace.shared.runningApplications.filter {
                guard let path = $0.bundleURL?.path else { return false }
                return path == bundle || path.hasPrefix(bundle + "/")
            }
            for app in apps {
                app.terminate()
                handled.insert(app.processIdentifier)
            }
            // Helpers inside the bundle quit with their app.
            if !apps.isEmpty {
                handled.formUnion(group.processes.filter { $0.path.hasPrefix(bundle + "/") }.map(\.pid))
            }
        }
        for process in group.processes where !handled.contains(process.pid) && canClose(process.pid) {
            kill(process.pid, force ? SIGKILL : SIGTERM)
        }
    }
}

// MARK: - Model

final class MemoryModel: ObservableObject {
    @Published var memory: SystemMemory?
    @Published var groups: [ProcessGroup] = []
    /// Targets already asked to quit: a second confirmation forces them.
    @Published var attempted: Set<String> = []
    private let queue = DispatchQueue(label: "memory-bar.sample")

    func refresh() {
        queue.async {
            let memory = SystemMemory.read()
            let groups = ProcessSampler.sample()
            DispatchQueue.main.async {
                self.memory = memory
                self.groups = groups
            }
        }
    }

    func close(group: ProcessGroup) {
        let key = "g:" + group.name
        Closer.close(group, force: attempted.contains(key))
        attempted.insert(key)
        refreshSoon()
    }

    func close(process: ProcessEntry) {
        let key = "p:\(process.pid)"
        Closer.close(process.pid, force: attempted.contains(key))
        attempted.insert(key)
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }
}

// MARK: - Views

struct UsageBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color(nsColor: usageColor(fraction)))
                    .frame(width: max(geo.size.height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}

struct SummaryView: View {
    let memory: SystemMemory
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memoria").font(.headline)
                Spacer()
                Text("\(gb(memory.used)) de \(gb(memory.total))").monospacedDigit()
            }
            UsageBar(fraction: Double(memory.used) / Double(memory.total))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    detail("Apps", gb(memory.app))
                    detail("Caché", gb(memory.cached))
                }
                GridRow {
                    detail("Wired", gb(memory.wired))
                    detail("Swap", gb(memory.swapUsed))
                }
                GridRow {
                    detail("Comprimida", gb(memory.compressed))
                    detail("Presión", pressureLabel(memory.pressure))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
        .frame(width: 150)
    }
}

struct CloseButton: View {
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ConfirmRow: View {
    let message: String
    let actionTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancelar", action: onCancel)
            Button(actionTitle, role: .destructive, action: onConfirm).tint(.red)
        }
        .controlSize(.small)
        .padding(.leading, 18)
        .padding(.vertical, 4)
    }
}

struct GroupRow: View {
    let group: ProcessGroup
    @ObservedObject var model: MemoryModel
    @Binding var expanded: Set<String>
    @Binding var confirming: String?
    private let maxProcesses = 25

    private var isExpanded: Bool { expanded.contains(group.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(nsImage: Icons.icon(for: group))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                Text(group.name).lineLimit(1).truncationMode(.middle)
                if group.processes.count > 1 {
                    Text("\(group.processes.count)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Text(gb(group.memory)).monospacedDigit()
                if Closer.canClose(group) {
                    CloseButton(help: "Cerrar \(group.name)") { confirming = "g:" + group.name }
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded { expanded.remove(group.name) } else { expanded.insert(group.name) }
            }

            if confirming == "g:" + group.name {
                let forced = model.attempted.contains("g:" + group.name)
                let count = group.processes.count
                ConfirmRow(message: count > 1 ? "Se cerrarán \(count) procesos." : "Se cerrará el proceso.",
                           actionTitle: forced ? "Forzar cierre" : "Cerrar",
                           onConfirm: { model.close(group: group); confirming = nil },
                           onCancel: { confirming = nil })
            }

            if isExpanded {
                let sorted = group.processes.sorted { $0.memory > $1.memory }
                ForEach(sorted.prefix(maxProcesses)) { process in
                    processRow(process)
                }
                if sorted.count > maxProcesses {
                    let rest = sorted.dropFirst(maxProcesses).reduce(0) { $0 + $1.memory }
                    HStack {
                        Text("\(sorted.count - maxProcesses) procesos más")
                        Spacer()
                        Text(gb(rest)).monospacedDigit()
                        Color.clear.frame(width: 16, height: 16)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func processRow(_ process: ProcessEntry) -> some View {
        let key = "p:\(process.pid)"
        HStack(spacing: 8) {
            Text(processLabel(process)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(gb(process.memory)).monospacedDigit()
            if Closer.canClose(process.pid) {
                CloseButton(help: "Cerrar este proceso") { confirming = key }
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 34)
        .padding(.vertical, 2)
        .help(process.command)
        if confirming == key {
            ConfirmRow(message: "Se cerrará \(processLabel(process)).",
                       actionTitle: model.attempted.contains(key) ? "Forzar cierre" : "Cerrar",
                       onConfirm: { model.close(process: process); confirming = nil },
                       onCancel: { confirming = nil })
                .padding(.leading, 16)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: MemoryModel
    @State private var expanded: Set<String> = []
    @State private var confirming: String?
    private let maxGroups = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let memory = model.memory {
                SummaryView(memory: memory)
            }
            Divider()
            Text("Consumo por app").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.groups.prefix(maxGroups)) { group in
                        GroupRow(group: group, model: model, expanded: $expanded, confirming: $confirming)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Abrir Monitor de Actividad") {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                }
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    let model = MemoryModel()
    private var titleTimer: Timer?
    private var listTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.delegate = self
        // Fixed size: letting SwiftUI resize the popover after it is shown grows it upwards, under the menu bar.
        let hosting = NSHostingController(rootView: ContentView(model: model))
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateStatusItem()
        titleTimer = schedule(every: 3) { [weak self] in self?.updateStatusItem() }
    }

    private func schedule(every seconds: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func updateStatusItem() {
        guard let memory = SystemMemory.read(), let button = statusItem.button else { return }
        let fraction = Double(memory.used) / Double(memory.total)
        button.image = statusBarImage(fraction: fraction)
        let text = "Memoria usada \(Int((fraction * 100).rounded()))%: \(gb(memory.used)) de \(gb(memory.total))"
        button.toolTip = text
        button.setAccessibilityLabel(text)
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        let available = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        popover.contentSize = NSSize(width: 380, height: min(620, available - 40))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        listTimer = schedule(every: 4) { [weak self] in self?.model.refresh() }
    }

    func popoverDidClose(_ notification: Notification) {
        listTimer?.invalidate()
        listTimer = nil
        model.attempted.removeAll()
    }
}

// `--dump` prints the same data the panel shows, for checking from a terminal.
if CommandLine.arguments.contains("--dump") {
    if let mem = SystemMemory.read() {
        print("used \(gb(mem.used)) / \(gb(mem.total)) app \(gb(mem.app)) wired \(gb(mem.wired)) compressed \(gb(mem.compressed)) cached \(gb(mem.cached)) swap \(gb(mem.swapUsed)) pressure \(pressureLabel(mem.pressure))")
    }
    for group in ProcessSampler.sample().prefix(15) {
        let icon = group.bundlePath.flatMap { Icons.hasOwnIcon($0) ? "app icon: \($0)" : nil }
            ?? "symbol: \(Icons.fallbackSymbol(for: group))"
        print(String(format: "%-40@ %10@  (%d)  [%@]  closable: %@", group.name as NSString, gb(group.memory) as NSString,
                     group.processes.count, icon as NSString, Closer.canClose(group) ? "yes" : "no"))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
