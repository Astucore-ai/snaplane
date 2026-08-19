import AppKit

enum Snapper {
    static func frames(
        for layout: Layout,
        screen: NSScreen,
        spacing: CGFloat,
        applySpacing: Bool,
        spanAll: Bool
    ) -> [CGRect] {
        let work = Geometry.workArea(for: screen, spanAll: spanAll)
        return layout.zones.map { Geometry.zoneFrame($0, in: work, spacing: spacing, applySpacing: applySpacing) }
    }

    static func highlightedZones(
        at cocoaPoint: NSPoint,
        layout: Layout,
        screen: NSScreen,
        settings: FZSettings,
        sticky: Set<Int>
    ) -> Set<Int> {
        let spacing = settings.spaceAroundZones ? CGFloat(settings.zoneSpacing) : 0
        let frames = frames(
            for: layout,
            screen: screen,
            spacing: spacing,
            applySpacing: settings.spaceAroundZones,
            spanAll: settings.spanZonesAcrossMonitors
        )
        var hits: [Int] = []
        for (idx, frame) in frames.enumerated() where frame.contains(cocoaPoint) {
            hits.append(idx)
        }

        var selected = Set<Int>()
        if hits.isEmpty {
            if let nearest = nearestZone(to: cocoaPoint, frames: frames, maxDistance: 36) {
                selected.insert(nearest)
            }
        } else if hits.count == 1 {
            selected.insert(hits[0])
        } else {
            selected.insert(pickOverlap(hits, frames: frames, point: cocoaPoint, policy: settings.overlapPolicy))
        }

        let dist = CGFloat(settings.adjacentHighlightDistance)
        if selected.count == 1, let a = selected.first {
            for (idx, frame) in frames.enumerated() where idx != a {
                if Geometry.shareEdge(frames[a], frame, slop: dist) {
                    let edgeBand = frames[a].insetBy(dx: -dist, dy: -dist).intersection(frame.insetBy(dx: -dist, dy: -dist))
                    if !edgeBand.isNull, edgeBand.insetBy(dx: -4, dy: -4).contains(cocoaPoint) {
                        selected.insert(idx)
                    }
                }
            }
        }

        return selected.union(sticky)
    }

    static func snap(_ window: AXUIElement, to indexes: [Int], layout: Layout, screen: NSScreen) {
        guard !indexes.isEmpty else { return }
        let settings = ZoneStore.shared.settings
        let spacing = settings.spaceAroundZones ? CGFloat(settings.zoneSpacing) : 0
        let all = frames(
            for: layout,
            screen: screen,
            spacing: spacing,
            applySpacing: settings.spaceAroundZones,
            spanAll: settings.spanZonesAcrossMonitors
        )
        let chosen = indexes.compactMap { all.indices.contains($0) ? all[$0] : nil }
        guard !chosen.isEmpty else { return }

        if let wid = WindowAX.windowID(of: window), ZoneStore.shared.originalFrames[wid] == nil {
            if let frame = WindowAX.cocoaFrame(of: window) {
                ZoneStore.shared.originalFrames[wid] = frame
            }
        }

        let target = Geometry.unionFrames(chosen)
        WindowAX.setCocoaFrame(window, target)

        if let wid = WindowAX.windowID(of: window), let pid = WindowAX.pid(of: window) {
            let key = Geometry.monitorKey(for: screen)
            ZoneStore.shared.snapped[wid] = SnappedWindow(
                windowID: wid,
                pid: pid,
                layoutId: layout.id,
                zoneIndexes: indexes.sorted(),
                monitorKey: key
            )
            if let bid = WindowAX.bundleId(for: pid) {
                ZoneStore.shared.rememberApp(bid, layoutId: layout.id, zoneIndexes: indexes.sorted(), monitorKey: key)
            }
        }
    }

    static func unsnap(_ window: AXUIElement) {
        guard ZoneStore.shared.settings.restoreSizeOnUnsnap else { return }
        guard let wid = WindowAX.windowID(of: window),
              let original = ZoneStore.shared.originalFrames[wid],
              let current = WindowAX.cocoaFrame(of: window) else { return }
        var restored = original
        restored.origin.x = current.midX - restored.width / 2
        restored.origin.y = current.midY - restored.height / 2
        WindowAX.setCocoaFrame(window, restored)
        ZoneStore.shared.snapped.removeValue(forKey: wid)
    }

    static func snapFocused(direction: Direction) {
        guard let window = WindowAX.focusedWindow() else { return }
        let settings = ZoneStore.shared.settings
        let screen: NSScreen
        if let frame = WindowAX.cocoaFrame(of: window) {
            screen = Geometry.screen(containingCocoa: frame)
        } else {
            screen = NSScreen.main ?? Geometry.primary
        }
        var layout = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: screen))
        let spacing = settings.spaceAroundZones ? CGFloat(settings.zoneSpacing) : 0
        var frames = frames(
            for: layout,
            screen: screen,
            spacing: spacing,
            applySpacing: settings.spaceAroundZones,
            spanAll: settings.spanZonesAcrossMonitors
        )
        guard !frames.isEmpty else { return }

        let currentIdx = currentZoneIndex(of: window, frames: frames)
        let next: Int
        switch settings.moveBasis {
        case .zoneIndex:
            switch direction {
            case .left: next = (currentIdx - 1 + frames.count) % frames.count
            case .right: next = (currentIdx + 1) % frames.count
            case .up, .down: next = currentIdx
            }
        case .relative:
            next = neighbor(from: currentIdx, frames: frames, direction: direction) ?? currentIdx
        }

        if settings.moveAcrossMonitors, next == currentIdx, direction == .left || direction == .right {
            if let other = adjacentMonitor(from: screen, direction: direction) {
                layout = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: other))
                frames = Snapper.frames(
                    for: layout,
                    screen: other,
                    spacing: spacing,
                    applySpacing: settings.spaceAroundZones,
                    spanAll: false
                )
                let idx = direction == .left ? (frames.count - 1) : 0
                if frames.indices.contains(idx) {
                    snap(window, to: [idx], layout: layout, screen: other)
                    return
                }
            }
        }
        snap(window, to: [next], layout: layout, screen: screen)
    }

    static func expandFocused(direction: Direction) {
        guard let window = WindowAX.focusedWindow() else { return }
        let settings = ZoneStore.shared.settings
        guard let frame = WindowAX.cocoaFrame(of: window) else { return }
        let screen = Geometry.screen(containingCocoa: frame)
        let layout = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: screen))
        let spacing = settings.spaceAroundZones ? CGFloat(settings.zoneSpacing) : 0
        let frames = frames(
            for: layout,
            screen: screen,
            spacing: spacing,
            applySpacing: settings.spaceAroundZones,
            spanAll: settings.spanZonesAcrossMonitors
        )
        let current = currentIndexes(of: window, frames: frames)
        guard let seed = current.first else {
            snapFocused(direction: direction)
            return
        }
        var set = Set(current)
        if let extra = neighbor(from: seed, frames: frames, direction: direction) {
            set.insert(extra)
        }
        snap(window, to: Array(set).sorted(), layout: layout, screen: screen)
    }

    static func cycleZone(next: Bool) {
        guard ZoneStore.shared.settings.cycleWindowsInZone else { return }
        guard let window = WindowAX.focusedWindow(),
              let wid = WindowAX.windowID(of: window),
              let snap = ZoneStore.shared.snapped[wid] else { return }
        let same = ZoneStore.shared.snapped.values
            .filter { $0.layoutId == snap.layoutId && $0.zoneIndexes == snap.zoneIndexes && $0.monitorKey == snap.monitorKey }
            .sorted { $0.windowID < $1.windowID }
        guard same.count > 1, let idx = same.firstIndex(where: { $0.windowID == wid }) else { return }
        let target = same[(idx + (next ? 1 : same.count - 1)) % same.count]
        for el in WindowAX.windows(for: target.pid) {
            if WindowAX.windowID(of: el) == target.windowID {
                WindowAX.raise(el)
                return
            }
        }
    }

    static func reflowSnappedWindows(layoutChanged: Bool) {
        let settings = ZoneStore.shared.settings
        if layoutChanged && !settings.matchWindowsOnLayoutChange { return }
        if !layoutChanged && !settings.keepWindowsOnResolutionChange { return }
        for (wid, snap) in ZoneStore.shared.snapped {
            guard let screen = NSScreen.screens.first(where: { Geometry.monitorKey(for: $0) == snap.monitorKey })
                    ?? NSScreen.main else { continue }
            let layout = ZoneStore.shared.layout(forMonitorKey: snap.monitorKey)
            for el in WindowAX.windows(for: snap.pid) {
                if WindowAX.windowID(of: el) == wid {
                    let indexes = snap.zoneIndexes.filter { layout.zones.indices.contains($0) }
                    if !indexes.isEmpty {
                        Snapper.snap(el, to: indexes, layout: layout, screen: screen)
                    }
                }
            }
        }
    }

    static func placeNewWindow(for app: NSRunningApplication) {
        let settings = ZoneStore.shared.settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let windows = WindowAX.windows(for: app.processIdentifier)
            guard let window = windows.first(where: { WindowAX.subrole(of: $0) == kAXStandardWindowSubrole as String })
                    ?? windows.first else { return }
            if let bid = app.bundleIdentifier, settings.moveNewWindowsToLastZone,
               let memory = ZoneStore.shared.appMemory[bid],
               let layout = ZoneStore.shared.layouts.first(where: { $0.id == memory.layoutId }) {
                let screen = NSScreen.screens.first { Geometry.monitorKey(for: $0) == memory.monitorKey }
                    ?? NSScreen.main ?? Geometry.primary
                snap(window, to: memory.zoneIndexes, layout: layout, screen: screen)
                return
            }
            if settings.moveNewWindowsToActiveMonitor, let screen = NSScreen.main {
                let layout = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: screen))
                snap(window, to: [0], layout: layout, screen: screen)
            }
        }
    }

    enum Direction { case left, right, up, down }

    private static func pickOverlap(_ hits: [Int], frames: [CGRect], point: NSPoint, policy: OverlapPolicy) -> Int {
        switch policy {
        case .smallest:
            return hits.min { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height } ?? hits[0]
        case .largest:
            return hits.max { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height } ?? hits[0]
        case .closestCenter:
            return hits.min {
                hypot(frames[$0].midX - point.x, frames[$0].midY - point.y)
                    < hypot(frames[$1].midX - point.x, frames[$1].midY - point.y)
            } ?? hits[0]
        }
    }

    private static func nearestZone(to point: NSPoint, frames: [CGRect], maxDistance: CGFloat) -> Int? {
        var best: Int?
        var bestD = maxDistance
        for (idx, frame) in frames.enumerated() {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let d = hypot(dx, dy)
            if d < bestD {
                bestD = d
                best = idx
            }
        }
        return best
    }

    private static func currentZoneIndex(of window: AXUIElement, frames: [CGRect]) -> Int {
        currentIndexes(of: window, frames: frames).first ?? 0
    }

    private static func currentIndexes(of window: AXUIElement, frames: [CGRect]) -> [Int] {
        if let wid = WindowAX.windowID(of: window),
           let snap = ZoneStore.shared.snapped[wid],
           snap.zoneIndexes.allSatisfy({ frames.indices.contains($0) }) {
            return snap.zoneIndexes
        }
        guard let frame = WindowAX.cocoaFrame(of: window) else { return [0] }
        var best = 0
        var bestArea: CGFloat = 0
        for (idx, z) in frames.enumerated() {
            let inter = z.intersection(frame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = idx
            }
        }
        return [best]
    }

    private static func neighbor(from index: Int, frames: [CGRect], direction: Direction) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        let src = frames[index]
        var best: Int?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (idx, frame) in frames.enumerated() where idx != index {
            let dx = frame.midX - src.midX
            let dy = frame.midY - src.midY
            let aligned: Bool
            let forward: Bool
            switch direction {
            case .left:
                forward = dx < -4
                aligned = abs(dy) <= max(src.height, frame.height)
            case .right:
                forward = dx > 4
                aligned = abs(dy) <= max(src.height, frame.height)
            case .up:
                forward = dy > 4
                aligned = abs(dx) <= max(src.width, frame.width)
            case .down:
                forward = dy < -4
                aligned = abs(dx) <= max(src.width, frame.width)
            }
            guard forward else { continue }
            let score = hypot(dx, dy) + (aligned ? 0 : 400)
            if score < bestScore {
                bestScore = score
                best = idx
            }
        }
        return best
    }

    private static func adjacentMonitor(from screen: NSScreen, direction: Direction) -> NSScreen? {
        let src = screen.frame
        return NSScreen.screens
            .filter { $0 !== screen }
            .min { a, b in
                switch direction {
                case .left: return a.frame.maxX > b.frame.maxX
                case .right: return a.frame.minX < b.frame.minX
                default: return true
                }
            }
            .flatMap { candidate in
                switch direction {
                case .left where candidate.frame.maxX <= src.minX + 8: return candidate
                case .right where candidate.frame.minX >= src.maxX - 8: return candidate
                default: return nil
                }
            }
    }
}
