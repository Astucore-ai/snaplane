import AppKit
import Carbon.HIToolbox

final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var global: Any?
    private var local: Any?

    private init() {}

    func start() {
        stop()
        global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event, consume: false)
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if self?.handle(event, consume: true) == true { return nil }
            return event
        }
    }

    func stop() {
        if let global = global { NSEvent.removeMonitor(global) }
        if let local = local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }

    @discardableResult
    private func handle(_ event: NSEvent, consume: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)
        let settings = ZoneStore.shared.settings

        let editorCombo = flags.contains(.control) && flags.contains(.option) && flags.contains(.shift)
            && !flags.contains(.command) && code == kVK_ANSI_Grave
        if editorCombo {
            DebugLog.write("hotkey editorCombo consume=\(consume) editingCanvas=\(EditorController.shared.isEditingCanvas)")
            DispatchQueue.main.async { EditorController.shared.toggle() }
            return true
        }

        // Canvas overlay owns arrows / Enter / Esc. Do not steal them for snap hotkeys.
        // Esc still cancels the overlay even if the canvas window lost key focus.
        if EditorController.shared.isEditingCanvas {
            if code == kVK_Escape {
                DispatchQueue.main.async { EditorController.shared.cancelCanvasIfEditing() }
                return true
            }
            return false
        }

        let settingsCombo = flags.contains(.control) && flags.contains(.option) && flags.contains(.shift)
            && !flags.contains(.command) && code == kVK_ANSI_Comma
        if settingsCombo {
            DispatchQueue.main.async { SettingsWindowController.shared.show() }
            return true
        }

        guard settings.enabled else { return false }

        if settings.quickLayoutSwitch,
           flags.contains(.control), flags.contains(.option), flags.contains(.command),
           let number = numberKey(code),
           let layout = ZoneStore.shared.layoutByHotkey(number) {
            DispatchQueue.main.async {
                let screen = NSScreen.main ?? Geometry.primary
                ZoneStore.shared.assign(layoutId: layout.id, toMonitorKey: Geometry.monitorKey(for: screen))
                if settings.flashZonesOnSwitch {
                    OverlayController.shared.flash(layout: layout, on: screen)
                }
                Snapper.reflowSnappedWindows(layoutChanged: true)
            }
            return true
        }

        if settings.cycleWindowsInZone,
           flags.contains(.control), flags.contains(.option), !flags.contains(.command) {
            if code == kVK_PageUp {
                DispatchQueue.main.async { Snapper.cycleZone(next: false) }
                return true
            }
            if code == kVK_PageDown {
                DispatchQueue.main.async { Snapper.cycleZone(next: true) }
                return true
            }
        }

        if settings.overrideSnapHotkeys,
           flags.contains(.control), flags.contains(.option),
           !flags.contains(.command), !flags.contains(.shift) {
            let expand = flags.contains(.control) && flags.contains(.option) && event.modifierFlags.contains(.function) == false
            _ = expand
            switch code {
            case kVK_LeftArrow:
                DispatchQueue.main.async { Snapper.snapFocused(direction: .left) }
                return true
            case kVK_RightArrow:
                DispatchQueue.main.async { Snapper.snapFocused(direction: .right) }
                return true
            case kVK_UpArrow:
                if settings.moveBasis == .relative {
                    DispatchQueue.main.async { Snapper.snapFocused(direction: .up) }
                    return true
                }
            case kVK_DownArrow:
                if settings.moveBasis == .relative {
                    DispatchQueue.main.async { Snapper.snapFocused(direction: .down) }
                    return true
                }
            default:
                break
            }
        }

        if settings.overrideSnapHotkeys,
           flags.contains(.control), flags.contains(.option), flags.contains(.command),
           !flags.contains(.shift) {
            switch code {
            case kVK_LeftArrow:
                DispatchQueue.main.async { Snapper.expandFocused(direction: .left) }
                return true
            case kVK_RightArrow:
                DispatchQueue.main.async { Snapper.expandFocused(direction: .right) }
                return true
            case kVK_UpArrow:
                DispatchQueue.main.async { Snapper.expandFocused(direction: .up) }
                return true
            case kVK_DownArrow:
                DispatchQueue.main.async { Snapper.expandFocused(direction: .down) }
                return true
            default:
                break
            }
        }
        return false
    }

    private func numberKey(_ code: Int) -> Int? {
        switch code {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        case kVK_ANSI_0: return 0
        default: return nil
        }
    }
}
