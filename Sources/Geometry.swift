import AppKit
import CoreGraphics

enum Geometry {
    static var primary: NSScreen {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens[0]
    }

    static func axPoint(fromCocoa point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    static func cocoaPoint(fromAX point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    static func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(atCocoa point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? primary
    }

    static func screen(containingCocoa rect: CGRect) -> NSScreen {
        var best = primary
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(rect)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    static func monitorKey(for screen: NSScreen) -> String {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() {
                return CFUUIDCreateString(nil, uuid) as String
            }
            return "display-\(num)"
        }
        return "frame-\(Int(screen.frame.minX))-\(Int(screen.frame.minY))-\(Int(screen.frame.width))-\(Int(screen.frame.height))"
    }

    static func workArea(for screen: NSScreen, spanAll: Bool) -> CGRect {
        if spanAll {
            return NSScreen.screens.reduce(CGRect.null) { $0.union($1.visibleFrame) }
        }
        return screen.visibleFrame
    }

    static func zoneFrame(_ zone: RelZone, in work: CGRect, spacing: CGFloat, applySpacing: Bool) -> CGRect {
        let insetWork = applySpacing ? work.insetBy(dx: spacing, dy: spacing) : work
        let raw = CGRect(
            x: insetWork.minX + CGFloat(zone.x) * insetWork.width,
            y: insetWork.minY + CGFloat(1 - zone.y - zone.h) * insetWork.height,
            width: CGFloat(zone.w) * insetWork.width,
            height: CGFloat(zone.h) * insetWork.height
        )
        if applySpacing && spacing > 0 {
            return raw.insetBy(dx: spacing / 2, dy: spacing / 2)
        }
        return raw
    }

    static func unionFrames(_ frames: [CGRect]) -> CGRect {
        guard let first = frames.first else { return .zero }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    static func shareEdge(_ a: CGRect, _ b: CGRect, slop: CGFloat) -> Bool {
        let verticalTouch = abs(a.maxX - b.minX) <= slop || abs(b.maxX - a.minX) <= slop
        let horizontalOverlap = a.minY < b.maxY - 2 && a.maxY > b.minY + 2
        if verticalTouch && horizontalOverlap { return true }
        let horizontalTouch = abs(a.maxY - b.minY) <= slop || abs(b.maxY - a.minY) <= slop
        let verticalOverlap = a.minX < b.maxX - 2 && a.maxX > b.minX + 2
        return horizontalTouch && verticalOverlap
    }
}
