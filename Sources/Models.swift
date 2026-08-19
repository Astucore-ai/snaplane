import AppKit
import Foundation

enum OverlapPolicy: String, Codable, CaseIterable {
    case smallest = "Smallest"
    case largest = "Largest"
    case closestCenter = "Closest center"
}

enum MoveBasis: String, Codable, CaseIterable {
    case zoneIndex = "Zone index"
    case relative = "Relative position"
}

enum LayoutKind: String, Codable {
    case template
    case grid
    case canvas
}

enum TemplateType: String, Codable, CaseIterable {
    case focus = "Focus"
    case columns = "Columns"
    case rows = "Rows"
    case grid = "Grid"
    case priority = "Priority Grid"
}

struct RelZone: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    func clamped() -> RelZone {
        var z = self
        z.x = min(max(z.x, 0), 1)
        z.y = min(max(z.y, 0), 1)
        z.w = min(max(z.w, 0.04), 1 - z.x)
        z.h = min(max(z.h, 0.04), 1 - z.y)
        return z
    }
}

struct Layout: Codable, Equatable {
    var id: String
    var name: String
    var kind: LayoutKind
    var template: TemplateType?
    var zoneCount: Int
    var columns: Int
    var rows: Int
    var zones: [RelZone]
    var hotkey: Int?

    static func makeTemplate(_ type: TemplateType, count: Int, columns: Int = 0, rows: Int = 0) -> Layout {
        let c = max(1, count)
        var layout = Layout(
            id: UUID().uuidString,
            name: type.rawValue,
            kind: .template,
            template: type,
            zoneCount: c,
            columns: columns,
            rows: rows,
            zones: [],
            hotkey: nil
        )
        layout.rebuildZones()
        return layout
    }

    mutating func rebuildZones() {
        switch kind {
        case .canvas:
            if zones.isEmpty {
                zones = [RelZone(x: 0.1, y: 0.1, w: 0.35, h: 0.8)]
            }
        case .grid:
            let cols = max(1, columns)
            let rws = max(1, rows)
            zoneCount = cols * rws
            zones = Layout.gridZones(columns: cols, rows: rws)
        case .template:
            let type = template ?? .columns
            zones = Layout.templateZones(type, count: max(1, zoneCount))
        }
    }

    static func templateZones(_ type: TemplateType, count: Int) -> [RelZone] {
        let n = max(1, count)
        switch type {
        case .focus:
            if n == 1 { return [RelZone(x: 0, y: 0, w: 1, h: 1)] }
            let mainW = n == 2 ? 0.7 : 0.62
            var result = [RelZone(x: 0, y: 0, w: mainW, h: 1)]
            let rest = n - 1
            for i in 0..<rest {
                result.append(RelZone(
                    x: mainW,
                    y: Double(i) / Double(rest),
                    w: 1 - mainW,
                    h: 1 / Double(rest)
                ))
            }
            return result
        case .columns:
            return (0..<n).map { i in
                RelZone(x: Double(i) / Double(n), y: 0, w: 1 / Double(n), h: 1)
            }
        case .rows:
            return (0..<n).map { i in
                RelZone(x: 0, y: Double(i) / Double(n), w: 1, h: 1 / Double(n))
            }
        case .grid:
            let cols = Int(ceil(sqrt(Double(n))))
            let rws = Int(ceil(Double(n) / Double(cols)))
            var result: [RelZone] = []
            for i in 0..<n {
                let c = i % cols
                let r = i / cols
                let isLastRow = r == rws - 1
                let colsInRow = isLastRow ? (n - r * cols) : cols
                result.append(RelZone(
                    x: Double(c) / Double(colsInRow),
                    y: Double(r) / Double(rws),
                    w: 1 / Double(colsInRow),
                    h: 1 / Double(rws)
                ))
            }
            return result
        case .priority:
            if n == 1 { return [RelZone(x: 0, y: 0, w: 1, h: 1)] }
            if n == 2 {
                return [
                    RelZone(x: 0, y: 0, w: 0.5, h: 1),
                    RelZone(x: 0.5, y: 0, w: 0.5, h: 1)
                ]
            }
            let centerW = 0.5
            let sideW = (1 - centerW) / 2
            var result = [RelZone(x: sideW, y: 0, w: centerW, h: 1)]
            let remaining = n - 1
            let leftCount = remaining / 2
            let rightCount = remaining - leftCount
            if leftCount == 0 {
                result.append(RelZone(x: 0, y: 0, w: sideW, h: 1))
            } else {
                for i in 0..<leftCount {
                    result.append(RelZone(
                        x: 0,
                        y: Double(i) / Double(leftCount),
                        w: sideW,
                        h: 1 / Double(leftCount)
                    ))
                }
            }
            if rightCount == 0 {
                result.append(RelZone(x: sideW + centerW, y: 0, w: sideW, h: 1))
            } else {
                for i in 0..<rightCount {
                    result.append(RelZone(
                        x: sideW + centerW,
                        y: Double(i) / Double(rightCount),
                        w: sideW,
                        h: 1 / Double(rightCount)
                    ))
                }
            }
            return result
        }
    }

    static func gridZones(columns: Int, rows: Int) -> [RelZone] {
        var result: [RelZone] = []
        for r in 0..<rows {
            for c in 0..<columns {
                result.append(RelZone(
                    x: Double(c) / Double(columns),
                    y: Double(r) / Double(rows),
                    w: 1 / Double(columns),
                    h: 1 / Double(rows)
                ))
            }
        }
        return result
    }
}

struct AppZoneMemory: Codable {
    var layoutId: String
    var zoneIndexes: [Int]
    var monitorKey: String
}

struct FZSettings: Codable {
    var enabled: Bool = true
    var holdShiftToActivate: Bool = true
    var secondaryMouseToggle: Bool = false
    var middleMouseMultiZone: Bool = false
    var showZonesOnAllMonitors: Bool = false
    var spanZonesAcrossMonitors: Bool = false
    var overlapPolicy: OverlapPolicy = .smallest
    var showZoneNumbers: Bool = true
    var opacityPercent: Int = 50
    var highlightHex: String = "0078D4"
    var inactiveHex: String = "1F1F1F"
    var borderHex: String = "FFFFFF"
    var numberHex: String = "FFFFFF"
    var spaceAroundZones: Bool = true
    var zoneSpacing: Int = 16
    var adjacentHighlightDistance: Int = 16
    var keepWindowsOnResolutionChange: Bool = true
    var matchWindowsOnLayoutChange: Bool = true
    var moveNewWindowsToLastZone: Bool = false
    var moveNewWindowsToActiveMonitor: Bool = false
    var restoreSizeOnUnsnap: Bool = true
    var allowPopupWindows: Bool = false
    var allowChildWindows: Bool = false
    var cycleWindowsInZone: Bool = true
    var overrideSnapHotkeys: Bool = true
    var moveBasis: MoveBasis = .relative
    var moveAcrossMonitors: Bool = false
    var quickLayoutSwitch: Bool = true
    var flashZonesOnSwitch: Bool = true
    var excludedApps: String = "Finder\nSystem Settings\nSystem Preferences\nNotification Center\nSpotlight"
    var editorShortcutDisplay: String = "⌃⌥⇧`"
    var launchAtLogin: Bool = true

    static var `default`: FZSettings { FZSettings() }
}

struct StorePayload: Codable {
    var settings: FZSettings
    var layouts: [Layout]
    var monitorLayouts: [String: String]
    var appMemory: [String: AppZoneMemory]
}

final class ZoneStore {
    static let shared = ZoneStore()

    private(set) var settings: FZSettings
    private(set) var layouts: [Layout]
    private(set) var monitorLayouts: [String: String]
    private(set) var appMemory: [String: AppZoneMemory]
    var snapped: [CGWindowID: SnappedWindow] = [:]
    var originalFrames: [CGWindowID: CGRect] = [:]

    private let url: URL
    private let queue = DispatchQueue(label: "com.astucore.snaplane.store")

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snaplane", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(StorePayload.self, from: data) {
            settings = payload.settings
            layouts = payload.layouts
            monitorLayouts = payload.monitorLayouts
            appMemory = payload.appMemory
        } else {
            settings = .default
            layouts = ZoneStore.defaultLayouts()
            monitorLayouts = [:]
            appMemory = [:]
            save()
        }
        if layouts.isEmpty {
            layouts = ZoneStore.defaultLayouts()
            save()
        }
        migrateHotkeysIfNeeded()
    }

    private func migrateHotkeysIfNeeded() {
        var changed = false
        if !layouts.contains(where: { $0.name == "Four Columns" }) {
            var four = Layout.makeTemplate(.columns, count: 4)
            four.name = "Four Columns"
            four.hotkey = 2
            layouts.insert(four, at: min(1, layouts.count))
            changed = true
        }
        if layouts.allSatisfy({ $0.hotkey == nil }) {
            let names = ["Columns": 1, "Four Columns": 2, "Focus": 3, "Grid": 4, "Priority Grid": 5]
            for i in layouts.indices {
                if let n = names[layouts[i].name] {
                    layouts[i].hotkey = n
                    changed = true
                }
            }
        }
        if changed { save() }
    }

    static func defaultLayouts() -> [Layout] {
        var columns = Layout.makeTemplate(.columns, count: 3)
        columns.name = "Columns"
        columns.hotkey = 1
        var four = Layout.makeTemplate(.columns, count: 4)
        four.name = "Four Columns"
        four.hotkey = 2
        var focus = Layout.makeTemplate(.focus, count: 3)
        focus.name = "Focus"
        focus.hotkey = 3
        var rows = Layout.makeTemplate(.rows, count: 2)
        rows.name = "Rows"
        var grid = Layout.makeTemplate(.grid, count: 4)
        grid.name = "Grid"
        grid.hotkey = 4
        var priority = Layout.makeTemplate(.priority, count: 3)
        priority.name = "Priority Grid"
        priority.hotkey = 5
        return [columns, four, focus, rows, grid, priority]
    }

    func save() {
        let payload = StorePayload(
            settings: settings,
            layouts: layouts,
            monitorLayouts: monitorLayouts,
            appMemory: appMemory
        )
        queue.async { [url] in
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func updateSettings(_ mutate: (inout FZSettings) -> Void) {
        mutate(&settings)
        save()
        NotificationCenter.default.post(name: .fzSettingsChanged, object: nil)
    }

    func upsertLayout(_ layout: Layout) {
        if let idx = layouts.firstIndex(where: { $0.id == layout.id }) {
            layouts[idx] = layout
        } else {
            layouts.append(layout)
        }
        save()
        NotificationCenter.default.post(name: .fzLayoutsChanged, object: nil)
    }

    func deleteLayout(id: String) {
        layouts.removeAll { $0.id == id }
        for key in monitorLayouts.keys where monitorLayouts[key] == id {
            monitorLayouts[key] = nil
        }
        if layouts.isEmpty {
            layouts = ZoneStore.defaultLayouts()
        }
        save()
        NotificationCenter.default.post(name: .fzLayoutsChanged, object: nil)
    }

    func layout(forMonitorKey key: String) -> Layout {
        if let id = monitorLayouts[key], let layout = layouts.first(where: { $0.id == id }) {
            return layout
        }
        return layouts[0]
    }

    func assign(layoutId: String, toMonitorKey key: String) {
        monitorLayouts[key] = layoutId
        save()
        NotificationCenter.default.post(name: .fzLayoutsChanged, object: nil)
    }

    func layoutByHotkey(_ number: Int) -> Layout? {
        layouts.first { $0.hotkey == number }
    }

    func rememberApp(_ bundleId: String, layoutId: String, zoneIndexes: [Int], monitorKey: String) {
        appMemory[bundleId] = AppZoneMemory(layoutId: layoutId, zoneIndexes: zoneIndexes, monitorKey: monitorKey)
        save()
    }
}

struct SnappedWindow {
    var windowID: CGWindowID
    var pid: pid_t
    var layoutId: String
    var zoneIndexes: [Int]
    var monitorKey: String
}

extension Notification.Name {
    static let fzSettingsChanged = Notification.Name("fzSettingsChanged")
    static let fzLayoutsChanged = Notification.Name("fzLayoutsChanged")
    static let fzEnabledChanged = Notification.Name("fzEnabledChanged")
}

enum FZColor {
    static func hex(_ string: String, alpha: CGFloat = 1) -> NSColor {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            return NSColor.systemBlue.withAlphaComponent(alpha)
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
