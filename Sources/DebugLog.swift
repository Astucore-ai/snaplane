import AppKit
import Foundation

enum DebugLog {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Snaplane.debug.log")

    static var enabled: Bool {
        CommandLine.arguments.contains("--debug-canvas")
            || UserDefaults.standard.bool(forKey: "FZDebugLog")
    }

    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(isoStamp())  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) == false {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func dumpWindows(_ tag: String) {
        let policy: String
        switch NSApp.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        write("\(tag) appActive=\(NSApp.isActive) policy=\(policy) keyWindow=\(describe(NSApp.keyWindow)) mainWindow=\(describe(NSApp.mainWindow)) first=\(String(describing: NSApp.keyWindow?.firstResponder))")
        for (i, win) in NSApp.windows.enumerated() {
            write("  win[\(i)] \(describe(win)) visible=\(win.isVisible) key=\(win.isKeyWindow) main=\(win.isMainWindow) canKey=\(win.canBecomeKey) ignoresMouse=\(win.ignoresMouseEvents) level=\(win.level.rawValue) frame=\(win.frame) first=\(String(describing: win.firstResponder))")
        }
    }

    private static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let title = window.title.isEmpty ? String(describing: type(of: window)) : window.title
        return "\(title)#\(ObjectIdentifier(window))"
    }

    private static func isoStamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
