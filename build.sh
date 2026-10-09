#!/bin/zsh
# Builds MemoryBar.app and installs it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MemoryBar.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 Sources/*.swift -o "$APP/Contents/MacOS/MemoryBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/MemoryBar.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/MemoryBar.app"
