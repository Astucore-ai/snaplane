import AppKit
import CoreGraphics

final class DragMonitor {
    static let shared = DragMonitor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var dragging = false
    private var zonesOn = false
    private var startPoint = NSPoint.zero
    private var window: AXUIElement?
    private var sticky = Set<Int>()
    private var lastHighlight = Set<Int>()
    private var lastScreen: NSScreen?

    private init() {}

    func start() {
        stop()
        guard WindowAX.isTrusted(prompt: false) else { return }

        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<DragMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.enqueue(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else { return }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        endDrag(snap: false)
    }

    private func enqueue(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let location = event.location
        let flags = event.flags
        DispatchQueue.main.async { [weak self] in
            self?.handle(type: type, location: location, flags: flags)
        }
    }

    private func handle(type: CGEventType, location: CGPoint, flags: CGEventFlags) {
        guard ZoneStore.shared.settings.enabled, EditorController.shared.isOpen == false else { return }

        let cocoa = Geometry.cocoaPoint(fromAX: location)
        switch type {
        case .leftMouseDown:
            beginPotential(at: cocoa)
        case .leftMouseDragged:
            updateDrag(at: cocoa, flags: flags)
        case .leftMouseUp:
            finish(at: cocoa)
        case .rightMouseDown:
            if dragging, ZoneStore.shared.settings.secondaryMouseToggle {
                toggleZones(at: cocoa)
            }
        case .otherMouseDown:
            if dragging, ZoneStore.shared.settings.middleMouseMultiZone {
                sticky.formUnion(lastHighlight)
                refresh(at: cocoa)
            }
        case .flagsChanged:
            if dragging {
                let shift = flags.contains(.maskShift)
                let ctrl = flags.contains(.maskControl)
                if ZoneStore.shared.settings.holdShiftToActivate {
                    if shift && !zonesOn { turnZonesOn(at: cocoa) }
                    if !shift && zonesOn && sticky.isEmpty { turnZonesOff() }
                }
                if ctrl, let idx = lastHighlight.first {
                    sticky.insert(idx)
                }
                refresh(at: cocoa)
            }
        default:
            break
        }
    }

    private func beginPotential(at point: NSPoint) {
        window = nil
        dragging = false
        zonesOn = false
        sticky.removeAll()
        lastHighlight.removeAll()
        startPoint = point
        guard let el = WindowAX.window(atCocoa: point) else { return }
        let excluded = ZoneStore.shared.settings.excludedApps
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        if WindowAX.isExcluded(
            el,
            excluded: excluded,
            allowPopup: ZoneStore.shared.settings.allowPopupWindows,
            allowChild: ZoneStore.shared.settings.allowChildWindows
        ) {
            return
        }
        window = el
    }

    private func updateDrag(at point: NSPoint, flags: CGEventFlags) {
        guard window != nil else { return }
        let dist = hypot(point.x - startPoint.x, point.y - startPoint.y)
        if !dragging {
            if dist < 6 { return }
            dragging = true
            if !ZoneStore.shared.settings.holdShiftToActivate {
                turnZonesOn(at: point)
            } else if flags.contains(.maskShift) {
                turnZonesOn(at: point)
            }
        }
        if flags.contains(.maskControl), let idx = lastHighlight.first {
            sticky.insert(idx)
        }
        if zonesOn { refresh(at: point) }
    }

    private func finish(at point: NSPoint) {
        let shouldSnap = zonesOn && !lastHighlight.isEmpty && window != nil
        if shouldSnap, let window = window, let screen = lastScreen {
            let layout = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: screen))
            Snapper.snap(window, to: Array(lastHighlight).sorted(), layout: layout, screen: screen)
        } else if dragging, let window = window, zonesOn == false || lastHighlight.isEmpty {
            if let wid = WindowAX.windowID(of: window), ZoneStore.shared.snapped[wid] != nil {
                Snapper.unsnap(window)
            }
        }
        endDrag(snap: false)
    }

    private func endDrag(snap: Bool) {
        dragging = false
        zonesOn = false
        window = nil
        sticky.removeAll()
        lastHighlight.removeAll()
        lastScreen = nil
        OverlayController.shared.hide()
    }

    private func toggleZones(at point: NSPoint) {
        if zonesOn { turnZonesOff() } else { turnZonesOn(at: point) }
    }

    private func turnZonesOn(at point: NSPoint) {
        zonesOn = true
        refresh(at: point)
    }

    private func turnZonesOff() {
        zonesOn = false
        lastHighlight.removeAll()
        OverlayController.shared.hide()
    }

    private func refresh(at point: NSPoint) {
        let screen = Geometry.screen(atCocoa: point)
        lastScreen = screen
        let layout = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: screen))
        lastHighlight = Snapper.highlightedZones(
            at: point,
            layout: layout,
            screen: screen,
            settings: ZoneStore.shared.settings,
            sticky: sticky
        )
        OverlayController.shared.show(highlighted: lastHighlight, cursor: point)
    }
}

