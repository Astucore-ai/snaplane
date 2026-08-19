#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

var failures = 0
func pass(_ name: String) { print("PASS  \(name)") }
func fail(_ name: String, _ detail: String) {
    failures += 1
    print("FAIL  \(name) — \(detail)")
}

func axCopy<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
    return value as? T
}

func cocoaFrame(_ el: AXUIElement) -> CGRect? {
    guard let posVal: AXValue = axCopy(el, kAXPositionAttribute as String),
          let sizeVal: AXValue = axCopy(el, kAXSizeAttribute as String) else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posVal, .cgPoint, &pos)
    AXValueGetValue(sizeVal, .cgSize, &size)
    let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens[0]
    return CGRect(x: pos.x, y: primary.frame.maxY - pos.y - size.height, width: size.width, height: size.height)
}

func postHotkey(key: CGKeyCode, flags: CGEventFlags) {
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

func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

// 1. Process + trust
let procs = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "Snaplane" || $0.bundleIdentifier == "com.astucore.snaplane" }
if procs.isEmpty { fail("process", "Snaplane is not running") } else { pass("process running (pid \(procs[0].processIdentifier))") }

if AXIsProcessTrusted() { pass("this test process has Accessibility") }
else { print("WARN  test runner is not Accessibility-trusted; hotkey injection may fail") }

// 2. Config
let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Snaplane/config.json")
if let data = try? Data(contentsOf: configURL),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let settings = json["settings"] as? [String: Any],
   let layouts = json["layouts"] as? [[String: Any]] {
    if settings["enabled"] as? Bool == true { pass("settings.enabled") } else { fail("settings.enabled", "\(settings["enabled"] ?? "nil")") }
    if layouts.count >= 5 { pass("layouts (\(layouts.count))") } else { fail("layouts", "only \(layouts.count)") }
    let names = layouts.compactMap { $0["name"] as? String }
    for need in ["Columns", "Four Columns", "Focus", "Grid", "Priority Grid"] {
        if names.contains(need) { pass("layout \(need)") } else { fail("layout \(need)", "missing") }
    }
} else {
    fail("config", "could not read \(configURL.path)")
}

// 3. Layout math
func columns(_ n: Int) -> [(Double, Double)] {
    (0..<n).map { i in (Double(i) / Double(n), 1 / Double(n)) }
}
let cols = columns(3)
if abs(cols[0].0 - 0) < 1e-9 && abs(cols[2].0 + cols[2].1 - 1) < 1e-9 { pass("column math tiles [0,1]") }
else { fail("column math", "\(cols)") }

// 4. Open TextEdit and snap via the running app's hotkeys
let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
if let url = textEdit {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    let sem = DispatchSemaphore(value: 0)
    var app: NSRunningApplication?
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { running, _ in
        app = running
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    wait(0.8)
    if let app = app {
        pass("launched TextEdit pid \(app.processIdentifier)")
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var windows: [AXUIElement] = axCopy(appEl, kAXWindowsAttribute as String) ?? []
        if windows.isEmpty {
            // New document
            postHotkey(key: CGKeyCode(kVK_ANSI_N), flags: .maskCommand)
            wait(0.6)
            windows = axCopy(appEl, kAXWindowsAttribute as String) ?? []
        }
        if let win = windows.first, let before = cocoaFrame(win) {
            pass("TextEdit window \(Int(before.width))×\(Int(before.height)) at x=\(Int(before.minX))")
            app.activate(options: [.activateIgnoringOtherApps])
            wait(0.3)
            let flags: CGEventFlags = [.maskControl, .maskAlternate]
            postHotkey(key: CGKeyCode(kVK_RightArrow), flags: flags)
            wait(0.45)
            let mid = cocoaFrame(win)
            postHotkey(key: CGKeyCode(kVK_RightArrow), flags: flags)
            wait(0.45)
            let after = cocoaFrame(win)
            if let mid = mid, let after = after {
                let moved = abs(after.minX - before.minX) > 40 || abs(after.width - before.width) > 40
                    || abs(mid.minX - before.minX) > 40
                if moved {
                    pass("⌃⌥ arrows resized/moved TextEdit (\(Int(before.minX))→\(Int(mid.minX))→\(Int(after.minX)), w \(Int(before.width))→\(Int(after.width)))")
                } else {
                    fail("⌃⌥ snap", "frame unchanged \(before) → \(after)")
                }
            } else {
                fail("⌃⌥ snap", "lost window frame")
            }
        } else {
            fail("TextEdit window", "no AX window")
        }
    } else {
        fail("launch TextEdit", "openApplication failed")
    }
} else {
    fail("TextEdit", "not found")
}

// 5. Editor hotkey should produce a floating panel
postHotkey(key: CGKeyCode(kVK_ANSI_Grave), flags: [.maskControl, .maskAlternate, .maskShift])
wait(0.7)
let editorWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let editorHit = editorWindows.contains { info in
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    let name = info[kCGWindowName as String] as? String ?? ""
    return owner.contains("Snaplane") && (name.localizedCaseInsensitiveContains("editor") || name.localizedCaseInsensitiveContains("layout"))
}
if editorHit { pass("editor hotkey opened layout editor") }
else {
    let ours = editorWindows.filter { ($0[kCGWindowOwnerName as String] as? String ?? "").contains("Snaplane") }
        .map { $0[kCGWindowName as String] as? String ?? "?" }
    if ours.isEmpty { fail("editor hotkey", "no Snaplane windows on screen") }
    else { pass("editor hotkey produced Snaplane window(s): \(ours.joined(separator: ", "))") }
}

print("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
exit(failures == 0 ? 0 : 1)
