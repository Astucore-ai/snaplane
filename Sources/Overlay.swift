import AppKit

final class OverlayController {
    static let shared = OverlayController()

    private var windows: [NSWindow] = []
    private var flashWork: DispatchWorkItem?

    private init() {}

    func hide() {
        flashWork?.cancel()
        for window in windows {
            window.orderOut(nil)
        }
    }

    func show(
        highlighted: Set<Int>,
        cursor: NSPoint,
        forceAllMonitors: Bool? = nil,
        layoutOverride: Layout? = nil,
        monitorOverride: NSScreen? = nil
    ) {
        let store = ZoneStore.shared
        let settings = store.settings
        let allMonitors = forceAllMonitors ?? settings.showZonesOnAllMonitors
        let span = settings.spanZonesAcrossMonitors
        let target = monitorOverride ?? Geometry.screen(atCocoa: cursor)

        rebuildWindowsIfNeeded()

        for window in windows {
            guard let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame == window.frame }) else {
                window.orderOut(nil)
                continue
            }
            let onTarget = screen === target || screen.frame == target.frame
            if !allMonitors && !span && !onTarget {
                window.orderOut(nil)
                continue
            }

            let layout = layoutOverride ?? store.layout(forMonitorKey: Geometry.monitorKey(for: screen))
            let work = Geometry.workArea(for: screen, spanAll: span)
            let spacing = settings.spaceAroundZones ? CGFloat(settings.zoneSpacing) : 0
            var drawn: [ZoneDraw] = []
            for (idx, zone) in layout.zones.enumerated() {
                let global = Geometry.zoneFrame(zone, in: work, spacing: spacing, applySpacing: settings.spaceAroundZones)
                let local = global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                drawn.append(ZoneDraw(index: idx, rect: local, highlighted: highlighted.contains(idx)))
            }
            if let view = window.contentView as? ZoneCanvasView {
                view.model = ZoneCanvasModel(
                    zones: drawn,
                    opacity: CGFloat(settings.opacityPercent) / 100,
                    highlight: FZColor.hex(settings.highlightHex),
                    inactive: FZColor.hex(settings.inactiveHex),
                    border: FZColor.hex(settings.borderHex),
                    number: FZColor.hex(settings.numberHex),
                    showNumbers: settings.showZoneNumbers
                )
                view.needsDisplay = true
            }
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
        }
    }

    func flash(layout: Layout, on screen: NSScreen, duration: TimeInterval = 0.55) {
        show(highlighted: [], cursor: NSPoint(x: screen.frame.midX, y: screen.frame.midY),
             forceAllMonitors: false, layoutOverride: layout, monitorOverride: screen)
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func rebuildWindowsIfNeeded() {
        if windows.count == NSScreen.screens.count,
           zip(windows, NSScreen.screens).allSatisfy({ abs($0.frame.width - $1.frame.width) < 1 }) {
            return
        }
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = EditorChrome.overlayLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.animationBehavior = .none
            window.contentView = ZoneCanvasView(frame: screen.frame)
            return window
        }
    }
}

struct ZoneDraw {
    var index: Int
    var rect: CGRect
    var highlighted: Bool
}

struct ZoneCanvasModel {
    var zones: [ZoneDraw] = []
    var opacity: CGFloat = 0.5
    var highlight: NSColor = .systemBlue
    var inactive: NSColor = .black
    var border: NSColor = .white
    var number: NSColor = .white
    var showNumbers: Bool = true
}

final class ZoneCanvasView: NSView {
    var model = ZoneCanvasModel()

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.08).setFill()
        dirtyRect.fill()

        for zone in model.zones {
            let path = NSBezierPath(roundedRect: zone.rect.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            let fill = zone.highlighted
                ? model.highlight.withAlphaComponent(0.25 + 0.55 * model.opacity)
                : model.inactive.withAlphaComponent(0.15 + 0.45 * model.opacity)
            fill.setFill()
            path.fill()
            let stroke = zone.highlighted
                ? model.highlight.withAlphaComponent(0.95)
                : model.border.withAlphaComponent(0.35 + 0.4 * model.opacity)
            stroke.setStroke()
            path.lineWidth = zone.highlighted ? 3 : 1.5
            path.stroke()

            if model.showNumbers {
                let label = "\(zone.index + 1)" as NSString
                let font = NSFont.systemFont(ofSize: min(42, max(18, zone.rect.height * 0.12)), weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: model.number.withAlphaComponent(zone.highlighted ? 1 : 0.8)
                ]
                let size = label.size(withAttributes: attrs)
                let origin = NSPoint(
                    x: zone.rect.midX - size.width / 2,
                    y: zone.rect.midY - size.height / 2
                )
                label.draw(at: origin, withAttributes: attrs)
            }
        }
    }
}
