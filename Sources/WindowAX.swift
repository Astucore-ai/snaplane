import AppKit
import ApplicationServices

enum WindowAX {
    static let systemWide = AXUIElementCreateSystemWide()
    static let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

    static func isTrusted(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        // A real AX call: launchd-started binaries can fail AXIsProcessTrusted()
        // even after the user enabled the app in System Settings.
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &value
        )
        if err == .success { return true }
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }

    static func window(atCocoa point: NSPoint) -> AXUIElement? {
        let ax = Geometry.axPoint(fromCocoa: point)
        var ref: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(ax.x), Float(ax.y), &ref)
        guard err == .success, let element = ref else { return nil }
        return windowAncestor(of: element)
    }

    static func windowAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let el = current else { return nil }
            if role(of: el) == kAXWindowRole as String {
                return el
            }
            current = parent(of: el)
        }
        return nil
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == ownPID { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if let win: AXUIElement = copy(appEl, kAXFocusedWindowAttribute as String) {
            return win
        }
        return copy(appEl, kAXMainWindowAttribute as String)
    }

    static func role(of el: AXUIElement) -> String? { copy(el, kAXRoleAttribute as String) }
    static func subrole(of el: AXUIElement) -> String? { copy(el, kAXSubroleAttribute as String) }
    static func title(of el: AXUIElement) -> String? { copy(el, kAXTitleAttribute as String) }

    static func pid(of el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        return pid
    }

    static func parent(of el: AXUIElement) -> AXUIElement? {
        copy(el, kAXParentAttribute as String)
    }

    static func cocoaFrame(of el: AXUIElement) -> CGRect? {
        guard let pos = axPoint(of: el), let size = axSize(of: el) else { return nil }
        return Geometry.cocoaRect(fromAX: CGRect(origin: pos, size: size))
    }

    static func setCocoaFrame(_ el: AXUIElement, _ rect: CGRect) {
        var pos = Geometry.axRect(fromCocoa: rect).origin
        var size = rect.size
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as String as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as String as CFString, sizeVal)
        }
        // Some apps apply size first better; retry position after size.
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as String as CFString, posVal)
        }
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        if let pid = pid(of: el),
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    static func windowID(of el: AXUIElement) -> CGWindowID? {
        typealias Fn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return fallbackWindowID(of: el)
        }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var id: CGWindowID = 0
        if fn(el, &id) == .success, id != 0 { return id }
        return fallbackWindowID(of: el)
    }

    static func bundleId(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    static func appName(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    static func isExcluded(_ el: AXUIElement, excluded: [String], allowPopup: Bool, allowChild: Bool) -> Bool {
        guard let p = pid(of: el) else { return true }
        if p == ownPID { return true }
        let name = (appName(for: p) ?? "").lowercased()
        let bid = (bundleId(for: p) ?? "").lowercased()
        for raw in excluded {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if token.isEmpty { continue }
            if name.contains(token) || bid.contains(token) { return true }
        }
        let sub = subrole(of: el) ?? ""
        if !allowPopup && (sub == kAXDialogSubrole as String || sub == "AXSystemDialog" || sub == "AXFloatingWindow") {
            return true
        }
        if !allowChild && sub == kAXUnknownSubrole as String {
            return true
        }
        if subrole(of: el) == kAXStandardWindowSubrole as String { return false }
        if allowPopup || allowChild { return false }
        return sub != kAXStandardWindowSubrole as String && !sub.isEmpty && sub != "AXStandardWindow"
    }

    static func windows(for pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func axPoint(of el: AXUIElement) -> CGPoint? {
        guard let value: AXValue = copy(el, kAXPositionAttribute as String) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(of el: AXUIElement) -> CGSize? {
        guard let value: AXValue = copy(el, kAXSizeAttribute as String) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func fallbackWindowID(of el: AXUIElement) -> CGWindowID? {
        guard let frame = cocoaFrame(of: el), let p = pid(of: el) else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let title = self.title(of: el)
        for item in info {
            guard let owner = item[kCGWindowOwnerPID as String] as? pid_t, owner == p else { continue }
            guard let bounds = item[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let axBounds = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let cocoa = Geometry.cocoaRect(fromAX: axBounds)
            if abs(cocoa.minX - frame.minX) < 4 && abs(cocoa.minY - frame.minY) < 4
                && abs(cocoa.width - frame.width) < 8 && abs(cocoa.height - frame.height) < 8 {
                return item[kCGWindowNumber as String] as? CGWindowID
            }
            if let t = title, t.isEmpty == false,
               let wt = item[kCGWindowName as String] as? String, wt == t {
                return item[kCGWindowNumber as String] as? CGWindowID
            }
        }
        return nil
    }
}
