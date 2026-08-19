#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) {
        down.flags = flags
        down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}

func snaplanePIDs() -> [pid_t] {
    NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == "com.astucore.snaplane" || $0.localizedName == "Snaplane" }
        .map(\.processIdentifier)
}

func killSnaplane() {
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.astucore.snaplane" || app.localizedName == "Snaplane" {
        app.terminate()
    }
    wait(0.4)
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.astucore.snaplane" || app.localizedName == "Snaplane" {
        app.forceTerminate()
    }
    wait(0.3)
}

let binary = "/Applications/Snaplane.app/Contents/MacOS/Snaplane"
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Snaplane.debug.log")

print("AX trusted: \(AXIsProcessTrusted())")
print("killing existing Snaplane…")
killSnaplane()
try? "".write(to: logURL, atomically: true, encoding: .utf8)

print("launching --debug-canvas")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: binary)
proc.arguments = ["--debug-canvas"]
try proc.run()
wait(1.2)

print("snaplane pids: \(snaplanePIDs())")

func dumpCGWindows() {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let hits = list.filter { w in
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        return owner.contains("snaplane")
    }
    print("on-screen Snaplane windows: \(hits.count)")
    for w in hits {
        let name = w[kCGWindowName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("  layer=\(layer) name=\(name) bounds=\(bounds)")
    }
}
dumpCGWindows()

if AXIsProcessTrusted() {
    print("injecting N, LeftArrow, Escape")
    postKey(CGKeyCode(kVK_ANSI_N))
    wait(0.25)
    postKey(CGKeyCode(kVK_LeftArrow))
    wait(0.25)
    postKey(CGKeyCode(kVK_Escape))
    wait(0.4)
} else {
    print("SKIP key injection — this runner is not Accessibility-trusted")
    wait(0.4)
}

dumpCGWindows()
print("\n===== Snaplane.debug.log =====")
if let text = try? String(contentsOf: logURL, encoding: .utf8) {
    print(text)
} else {
    print("(missing)")
}

print("stopping debug instance")
killSnaplane()
print("done")
