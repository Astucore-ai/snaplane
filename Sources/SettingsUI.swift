import AppKit

final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var excludeField: NSTextView?

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Snaplane Settings"
        win.delegate = self
        win.center()
        win.contentView = makeContent()
        self.window = win
    }

    private func makeContent() -> NSView {
        let s = ZoneStore.shared.settings
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 1380))
        scroll.documentView = doc
        root.addSubview(scroll)

        var y: CGFloat = 1340
        func heading(_ text: String) {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: 15, weight: .semibold)
            f.frame = NSRect(x: 20, y: y, width: 580, height: 22)
            doc.addSubview(f)
            y -= 30
        }
        func check(_ title: String, key: WritableKeyPath<FZSettings, Bool>) {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = ZoneStore.shared.settings[keyPath: key] ? .on : .off
            b.frame = NSRect(x: 20, y: y, width: 580, height: 22)
            b.target = CheckboxHook.shared
            b.action = #selector(CheckboxHook.changed(_:))
            CheckboxHook.shared.bind(b, key: key)
            doc.addSubview(b)
            y -= 26
        }
        func note(_ text: String) {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            f.frame = NSRect(x: 40, y: y, width: 560, height: 18)
            doc.addSubview(f)
            y -= 22
        }

        heading("Activation")
        check("Enable Snaplane", key: \.enabled)
        check("Hold Shift to activate zones while dragging", key: \.holdShiftToActivate)
        check("Use a non-primary mouse button to toggle zone activation", key: \.secondaryMouseToggle)
        check("Use middle mouse button to toggle multiple zone spanning", key: \.middleMouseMultiZone)
        check("Show zones on all monitors while dragging", key: \.showZonesOnAllMonitors)
        check("Allow zones to span across monitors", key: \.spanZonesAcrossMonitors)

        heading("Appearance")
        check("Show zone numbers", key: \.showZoneNumbers)
        check("Show space around zones", key: \.spaceAroundZones)
        addSlider(doc, y: &y, title: "Opacity", min: 10, max: 90, value: s.opacityPercent) { Int($0) } write: { $0.opacityPercent = $1 }
        addSlider(doc, y: &y, title: "Space around zones", min: 0, max: 48, value: s.zoneSpacing) { Int($0) } write: { $0.zoneSpacing = $1 }
        addSlider(doc, y: &y, title: "Adjacent highlight distance", min: 0, max: 64, value: s.adjacentHighlightDistance) { Int($0) } write: { $0.adjacentHighlightDistance = $1 }
        addColorField(doc, y: &y, title: "Highlight color", value: s.highlightHex) { $0.highlightHex = $1 }
        addColorField(doc, y: &y, title: "Inactive color", value: s.inactiveHex) { $0.inactiveHex = $1 }
        addColorField(doc, y: &y, title: "Border color", value: s.borderHex) { $0.borderHex = $1 }
        addColorField(doc, y: &y, title: "Number color", value: s.numberHex) { $0.numberHex = $1 }

        heading("Window behavior")
        check("Keep windows in their zones when the screen resolution changes", key: \.keepWindowsOnResolutionChange)
        check("During layout changes, windows assigned to a zone match the new size", key: \.matchWindowsOnLayoutChange)
        check("Move newly created windows to the last known zone", key: \.moveNewWindowsToLastZone)
        check("Move newly created windows to the current active monitor", key: \.moveNewWindowsToActiveMonitor)
        check("Restore the original size of windows when unsnapping", key: \.restoreSizeOnUnsnap)
        check("Allow popup windows snapping", key: \.allowPopupWindows)
        check("Allow child windows snapping", key: \.allowChildWindows)

        heading("Keyboard")
        check("Override snap hotkeys (⌃⌥ arrows) to move between zones", key: \.overrideSnapHotkeys)
        check("Move windows between zones across all monitors", key: \.moveAcrossMonitors)
        check("Switch between windows in the current zone (⌃⌥ PageUp/PageDown)", key: \.cycleWindowsInZone)
        check("Enable quick layout switch (⌃⌥⌘ 0–9)", key: \.quickLayoutSwitch)
        check("Flash zones when switching layout", key: \.flashZonesOnSwitch)
        addPopup(doc, y: &y, title: "Move windows based on", items: MoveBasis.allCases.map(\.rawValue),
                 selected: s.moveBasis.rawValue) { raw in
            ZoneStore.shared.updateSettings { $0.moveBasis = MoveBasis(rawValue: raw) ?? .relative }
        }
        addPopup(doc, y: &y, title: "When multiple zones overlap", items: OverlapPolicy.allCases.map(\.rawValue),
                 selected: s.overlapPolicy.rawValue) { raw in
            ZoneStore.shared.updateSettings { $0.overlapPolicy = OverlapPolicy(rawValue: raw) ?? .smallest }
        }

        heading("Exclude applications")
        note("One name per line. Partial matches count (Chrome matches Google Chrome).")
        let tv = NSTextView(frame: NSRect(x: 20, y: y - 110, width: 580, height: 110))
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.string = s.excludedApps
        tv.delegate = ExcludeHook.shared
        ExcludeHook.shared.view = tv
        let clip = NSScrollView(frame: NSRect(x: 20, y: y - 110, width: 580, height: 110))
        clip.borderType = .bezelBorder
        clip.documentView = tv
        clip.hasVerticalScroller = true
        doc.addSubview(clip)
        y -= 140

        heading("Shortcuts")
        note("Open editor: ⌃⌥⇧`     Settings: ⌃⌥⇧,     Snap: ⌃⌥ ← → ↑ ↓")
        note("Expand across zones: ⌃⌥⌘ arrows     Layout hotkey: ⌃⌥⌘ 0–9")
        note("Cycle windows in a zone: ⌃⌥ PageUp / PageDown")

        heading("Startup")
        check("Launch at login and keep running", key: \.launchAtLogin)

        return root
    }

    private func addSlider(
        _ doc: NSView,
        y: inout CGFloat,
        title: String,
        min: Double,
        max: Double,
        value: Int,
        map: @escaping (Double) -> Int,
        write: @escaping (inout FZSettings, Int) -> Void
    ) {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 20, y: y, width: 220, height: 20)
        let slider = NSSlider(value: Double(value), minValue: min, maxValue: max, target: nil, action: nil)
        slider.frame = NSRect(x: 250, y: y, width: 280, height: 20)
        let hook = SliderHook(write: write, map: map)
        slider.target = hook
        slider.action = #selector(SliderHook.changed(_:))
        SliderHook.keep.append(hook)
        doc.addSubview(label)
        doc.addSubview(slider)
        y -= 28
    }

    private func addColorField(_ doc: NSView, y: inout CGFloat, title: String, value: String, write: @escaping (inout FZSettings, String) -> Void) {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 20, y: y, width: 220, height: 22)
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 250, y: y, width: 120, height: 22)
        let hook = TextHook(write: write)
        field.delegate = hook
        TextHook.keep.append(hook)
        doc.addSubview(label)
        doc.addSubview(field)
        y -= 28
    }

    private func addPopup(_ doc: NSView, y: inout CGFloat, title: String, items: [String], selected: String, write: @escaping (String) -> Void) {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 20, y: y, width: 220, height: 22)
        let pop = NSPopUpButton(frame: NSRect(x: 250, y: y, width: 280, height: 22), pullsDown: false)
        pop.addItems(withTitles: items)
        pop.selectItem(withTitle: selected)
        let hook = PopupHook(write: write)
        pop.target = hook
        pop.action = #selector(PopupHook.changed(_:))
        PopupHook.keep.append(hook)
        doc.addSubview(label)
        doc.addSubview(pop)
        y -= 32
    }
}

final class CheckboxHook: NSObject {
    static let shared = CheckboxHook()
    private var map: [ObjectIdentifier: WritableKeyPath<FZSettings, Bool>] = [:]

    func bind(_ button: NSButton, key: WritableKeyPath<FZSettings, Bool>) {
        map[ObjectIdentifier(button)] = key
    }

    @objc func changed(_ sender: NSButton) {
        guard let key = map[ObjectIdentifier(sender)] else { return }
        ZoneStore.shared.updateSettings { $0[keyPath: key] = sender.state == .on }
        if key == \FZSettings.enabled {
            NotificationCenter.default.post(name: .fzEnabledChanged, object: nil)
        }
        if key == \FZSettings.launchAtLogin {
            LaunchAtLogin.setEnabled(sender.state == .on)
        }
    }
}

final class SliderHook: NSObject {
    static var keep: [SliderHook] = []
    let write: (inout FZSettings, Int) -> Void
    let map: (Double) -> Int
    init(write: @escaping (inout FZSettings, Int) -> Void, map: @escaping (Double) -> Int) {
        self.write = write
        self.map = map
    }
    @objc func changed(_ sender: NSSlider) {
        let value = map(sender.doubleValue)
        ZoneStore.shared.updateSettings { write(&$0, value) }
    }
}

final class TextHook: NSObject, NSTextFieldDelegate {
    static var keep: [TextHook] = []
    let write: (inout FZSettings, String) -> Void
    init(write: @escaping (inout FZSettings, String) -> Void) { self.write = write }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        ZoneStore.shared.updateSettings { write(&$0, field.stringValue) }
    }
}

final class PopupHook: NSObject {
    static var keep: [PopupHook] = []
    let write: (String) -> Void
    init(write: @escaping (String) -> Void) { self.write = write }
    @objc func changed(_ sender: NSPopUpButton) {
        write(sender.titleOfSelectedItem ?? "")
    }
}

final class ExcludeHook: NSObject, NSTextViewDelegate {
    static let shared = ExcludeHook()
    weak var view: NSTextView?
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        ZoneStore.shared.updateSettings { $0.excludedApps = tv.string }
    }
}
