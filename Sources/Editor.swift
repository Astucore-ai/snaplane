import AppKit
import Carbon.HIToolbox

/// Borderless overlays cannot become key unless this is overridden — without it,
/// canvas-editor keyDown never fires and Esc/Enter/arrows appear to "hang".
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum EditorChrome {
    static let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
    static let uiLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)) + 2)
}

final class EditorController: NSObject, NSWindowDelegate {
    static let shared = EditorController()

    private(set) var isOpen = false
    private(set) var isEditingCanvas = false
    private var panel: NSPanel?
    private var previewTarget: NSScreen = Geometry.primary
    private var canvasSession: CanvasEditorSession?

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        isOpen = true
        NSApp.setActivationPolicy(.regular)
        previewTarget = NSScreen.main ?? Geometry.primary
        OverlayController.shared.show(
            highlighted: [],
            cursor: NSPoint(x: previewTarget.frame.midX, y: previewTarget.frame.midY),
            forceAllMonitors: false,
            layoutOverride: ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: previewTarget)),
            monitorOverride: previewTarget
        )
        showPanel()
        raisePanel()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        isOpen = false
        isEditingCanvas = false
        canvasSession?.close()
        canvasSession = nil
        let dying = panel
        panel = nil
        dying?.animationBehavior = .none
        dying?.orderOut(nil)
        DispatchQueue.main.async {
            dying?.animationBehavior = .none
            dying?.close()
        }
        OverlayController.shared.hide()
        NSApp.setActivationPolicy(.accessory)
    }

    func raisePanel() {
        guard let panel else { return }
        panel.level = EditorChrome.uiLevel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if isEditingCanvas == false {
            close()
        }
    }

    private func showPanel() {
        let width: CGFloat = 640
        let height: CGFloat = 680
        let screen = previewTarget
        let rect = NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Snaplane Layout Editor"
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = EditorChrome.uiLevel
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = EditorView(frame: NSRect(origin: .zero, size: rect.size), controller: self)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func selectMonitor(_ screen: NSScreen) {
        previewTarget = screen
        refreshPreview()
        if let view = panel?.contentView as? EditorView {
            view.reload()
        }
    }

    func apply(_ layout: Layout) {
        ZoneStore.shared.assign(layoutId: layout.id, toMonitorKey: Geometry.monitorKey(for: previewTarget))
        refreshPreview()
        if ZoneStore.shared.settings.flashZonesOnSwitch {
            OverlayController.shared.flash(layout: layout, on: previewTarget)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) { [weak self] in
                self?.refreshPreview()
            }
        }
        Snapper.reflowSnappedWindows(layoutChanged: true)
        (panel?.contentView as? EditorView)?.reload()
    }

    func refreshPreview() {
        guard isOpen, isEditingCanvas == false else { return }
        OverlayController.shared.show(
            highlighted: [],
            cursor: NSPoint(x: previewTarget.frame.midX, y: previewTarget.frame.midY),
            forceAllMonitors: false,
            layoutOverride: ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: previewTarget)),
            monitorOverride: previewTarget
        )
        raisePanel()
    }

    func createCustom(kind: LayoutKind) {
        var layout: Layout
        if kind == .canvas {
            layout = Layout(
                id: UUID().uuidString,
                name: "Custom Canvas",
                kind: .canvas,
                template: nil,
                zoneCount: 1,
                columns: 0,
                rows: 0,
                zones: [RelZone(x: 0.05, y: 0.05, w: 0.4, h: 0.9), RelZone(x: 0.5, y: 0.05, w: 0.45, h: 0.45), RelZone(x: 0.5, y: 0.55, w: 0.45, h: 0.4)],
                hotkey: nil
            )
        } else {
            layout = Layout(
                id: UUID().uuidString,
                name: "Custom Grid",
                kind: .grid,
                template: nil,
                zoneCount: 6,
                columns: 3,
                rows: 2,
                zones: Layout.gridZones(columns: 3, rows: 2),
                hotkey: nil
            )
        }
        ZoneStore.shared.upsertLayout(layout)
        apply(layout)
        openCanvasEditor(layout)
    }

    func openCanvasEditor(_ layout: Layout) {
        isEditingCanvas = true
        panel?.orderOut(nil)
        OverlayController.shared.hide()
        canvasSession = CanvasEditorSession(layout: layout, screen: previewTarget) { [weak self] updated in
            if let updated = updated {
                ZoneStore.shared.upsertLayout(updated)
                self?.apply(updated)
            }
            self?.isEditingCanvas = false
            self?.canvasSession = nil
            self?.showPanel()
            self?.refreshPreview()
        }
        canvasSession?.start()
    }

    func cancelCanvasIfEditing() {
        canvasSession?.cancelFromOutside()
    }

    var targetScreen: NSScreen { previewTarget }
}

final class EditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var controller: EditorController?
    private let table = NSTableView()
    private let stepper = NSStepper()
    private let countField = NSTextField(string: "3")
    private let spacing = NSSlider()
    private let monitorPop = NSPopUpButton()
    private let hotkeyPop = NSPopUpButton()
    private var layouts: [Layout] = []

    init(frame: NSRect, controller: EditorController) {
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        layouts = ZoneStore.shared.layouts
        table.reloadData()
        monitorPop.removeAllItems()
        for (i, screen) in NSScreen.screens.enumerated() {
            let name = "Display \(i + 1) — \(Int(screen.frame.width))×\(Int(screen.frame.height))"
            monitorPop.addItem(withTitle: name)
            if screen.frame == controller?.targetScreen.frame {
                monitorPop.selectItem(at: i)
            }
        }
        let current = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: controller?.targetScreen ?? Geometry.primary))
        countField.stringValue = "\(current.zoneCount)"
        stepper.integerValue = current.zoneCount
        spacing.integerValue = ZoneStore.shared.settings.zoneSpacing
        if let idx = layouts.firstIndex(where: { $0.id == current.id }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            syncHotkeyPop(layouts[idx])
        }
    }

    private func build() {
        let title = makeLabel("Choose a layout for the selected display", size: 13, weight: .semibold)
        let hint = makeLabel("Hold Shift and drag any window to snap it into a zone. ⌃⌥⇧` opens this editor.", size: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2

        monitorPop.target = self
        monitorPop.action = #selector(monitorChanged)

        stepper.minValue = 1
        stepper.maxValue = 8
        stepper.increment = 1
        stepper.target = self
        stepper.action = #selector(countChanged)
        countField.alignment = .center
        countField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countField.target = self
        countField.action = #selector(countTyped)

        spacing.minValue = 0
        spacing.maxValue = 48
        spacing.target = self
        spacing.action = #selector(spacingChanged)

        hotkeyPop.addItem(withTitle: "No hotkey")
        for n in 0...9 {
            hotkeyPop.addItem(withTitle: "⌃⌥⌘\(n)")
        }
        hotkeyPop.target = self
        hotkeyPop.action = #selector(hotkeyChanged)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layout"))
        col.title = "Layouts"
        table.addTableColumn(col)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 44
        table.allowsEmptySelection = false
        table.doubleAction = #selector(applySelected)
        table.target = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let apply = NSButton(title: "Apply", target: self, action: #selector(applySelected))
        apply.keyEquivalent = "\r"
        let edit = NSButton(title: "Edit custom…", target: self, action: #selector(editSelected))
        let del = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        let canvas = NSButton(title: "Create canvas layout", target: self, action: #selector(newCanvas))
        let grid = NSButton(title: "Create grid layout", target: self, action: #selector(newGrid))
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\u{1b}"

        let countLabel = makeLabel("Zones", size: 12, weight: .medium)
        let spaceLabel = makeLabel("Space around zones", size: 12, weight: .medium)
        let hotLabel = makeLabel("Hotkey", size: 12, weight: .medium)
        for label in [countLabel, spaceLabel, hotLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        countField.setContentHuggingPriority(.required, for: .horizontal)
        countField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        hotkeyPop.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        spacing.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let zonesSpacer = NSView()
        zonesSpacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let zonesRow = NSStackView(views: [countLabel, countField, stepper, zonesSpacer, hotLabel, hotkeyPop])
        zonesRow.orientation = .horizontal
        zonesRow.alignment = .centerY
        zonesRow.spacing = 8
        zonesRow.setCustomSpacing(16, after: stepper)

        let spaceRow = NSStackView(views: [spaceLabel, spacing])
        spaceRow.orientation = .horizontal
        spaceRow.alignment = .centerY
        spaceRow.spacing = 8

        let createRow = NSStackView(views: [canvas, grid])
        createRow.orientation = .horizontal
        createRow.alignment = .centerY
        createRow.spacing = 8
        createRow.distribution = .fill

        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let actionRow = NSStackView(views: [edit, del, actionSpacer, apply, done])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let stack = NSStackView(views: [title, hint, monitorPop, zonesRow, spaceRow, scroll, createRow, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(14, after: spaceRow)
        stack.setCustomSpacing(14, after: scroll)
        stack.setCustomSpacing(6, after: createRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

            monitorPop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            zonesRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            spaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            createRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layouts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let layout = layouts[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        let currentId = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: controller?.targetScreen ?? Geometry.primary)).id
        let mark = layout.id == currentId ? "● " : "    "
        let hot = layout.hotkey.map { "  ⌃⌥⌘\($0)" } ?? ""
        text.stringValue = "\(mark)\(layout.name)  ·  \(layout.zones.count) zones  ·  \(layout.kind.rawValue)\(hot)"
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard layouts.indices.contains(row) else { return }
        syncHotkeyPop(layouts[row])
        OverlayController.shared.show(
            highlighted: [],
            cursor: NSPoint(x: (controller?.targetScreen.frame.midX ?? 0), y: (controller?.targetScreen.frame.midY ?? 0)),
            forceAllMonitors: false,
            layoutOverride: layouts[row],
            monitorOverride: controller?.targetScreen
        )
        controller?.raisePanel()
    }

    @objc private func monitorChanged() {
        let idx = monitorPop.indexOfSelectedItem
        guard NSScreen.screens.indices.contains(idx) else { return }
        controller?.selectMonitor(NSScreen.screens[idx])
    }

    @objc private func countChanged() {
        countField.stringValue = "\(stepper.integerValue)"
        bumpCount(stepper.integerValue)
    }

    @objc private func countTyped() {
        let n = max(1, min(8, Int(countField.stringValue) ?? 3))
        stepper.integerValue = n
        bumpCount(n)
    }

    @objc private func spacingChanged() {
        ZoneStore.shared.updateSettings { $0.zoneSpacing = spacing.integerValue }
        controller?.refreshPreview()
    }

    @objc private func hotkeyChanged() {
        let row = table.selectedRow
        guard layouts.indices.contains(row) else { return }
        var layout = layouts[row]
        let idx = hotkeyPop.indexOfSelectedItem
        layout.hotkey = idx <= 0 ? nil : idx - 1
        if let hot = layout.hotkey {
            for i in 0..<ZoneStore.shared.layouts.count {
                if ZoneStore.shared.layouts[i].id != layout.id && ZoneStore.shared.layouts[i].hotkey == hot {
                    var other = ZoneStore.shared.layouts[i]
                    other.hotkey = nil
                    ZoneStore.shared.upsertLayout(other)
                }
            }
        }
        ZoneStore.shared.upsertLayout(layout)
        reload()
    }

    private func syncHotkeyPop(_ layout: Layout) {
        if let hot = layout.hotkey, (0...9).contains(hot) {
            hotkeyPop.selectItem(at: hot + 1)
        } else {
            hotkeyPop.selectItem(at: 0)
        }
    }

    @objc private func applySelected() {
        let row = table.selectedRow
        guard layouts.indices.contains(row) else { return }
        controller?.apply(layouts[row])
        controller?.close()
    }

    @objc private func editSelected() {
        let row = table.selectedRow
        guard layouts.indices.contains(row) else { return }
        var layout = layouts[row]
        if layout.kind == .template {
            layout.kind = .canvas
            layout.name = layout.name + " (custom)"
            layout.id = UUID().uuidString
            ZoneStore.shared.upsertLayout(layout)
        }
        controller?.openCanvasEditor(layout)
    }

    @objc private func deleteSelected() {
        let row = table.selectedRow
        guard layouts.indices.contains(row) else { return }
        ZoneStore.shared.deleteLayout(id: layouts[row].id)
        reload()
        controller?.refreshPreview()
    }

    @objc private func newCanvas() { controller?.createCustom(kind: .canvas) }
    @objc private func newGrid() { controller?.createCustom(kind: .grid) }
    @objc private func done() { controller?.close() }

    private func bumpCount(_ n: Int) {
        let row = table.selectedRow
        guard layouts.indices.contains(row) else { return }
        var layout = layouts[row]
        layout.zoneCount = n
        if layout.kind == .template {
            layout.rebuildZones()
            ZoneStore.shared.upsertLayout(layout)
            controller?.apply(layout)
        } else if layout.kind == .grid {
            layout.columns = n
            layout.rebuildZones()
            ZoneStore.shared.upsertLayout(layout)
            controller?.apply(layout)
        }
        reload()
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.lineBreakMode = .byWordWrapping
        return f
    }
}

final class CanvasEditorSession: NSObject, NSWindowDelegate {
    private var layout: Layout
    private let screen: NSScreen
    private let finish: (Layout?) -> Void
    private var window: NSWindow?
    private var view: CanvasEditView?
    private var keyMonitor: Any?
    private var finished = false

    init(layout: Layout, screen: NSScreen, finish: @escaping (Layout?) -> Void) {
        self.layout = layout
        self.screen = screen
        self.finish = finish
    }

    func start() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let win = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.setFrame(screen.frame, display: true)
        win.animationBehavior = .none
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = EditorChrome.uiLevel
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        win.isMovable = false
        win.delegate = self
        let view = CanvasEditView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            layout: layout,
            screen: screen
        ) { [weak self] in
            self?.saveAndClose()
        } cancel: { [weak self] in
            self?.cancel()
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        self.window = win
        self.view = view
        installKeyMonitor()
        DebugLog.write("canvas start makeKey isKey=\(win.isKeyWindow) canKey=\(win.canBecomeKey) first=\(String(describing: win.firstResponder)) appActive=\(NSApp.isActive)")
        DebugLog.dumpWindows("canvas-start")
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.makeFirstResponder(self?.view)
            NSApp.activate(ignoringOtherApps: true)
            if let win = self?.window {
                DebugLog.write("canvas async isKey=\(win.isKeyWindow) first=\(String(describing: win.firstResponder)) appActive=\(NSApp.isActive)")
            }
            DebugLog.dumpWindows("canvas-async")
        }
    }

    func close() {
        removeKeyMonitor()
        let dying = window
        window = nil
        view = nil
        dying?.animationBehavior = .none
        dying?.orderOut(nil)
        DispatchQueue.main.async {
            dying?.animationBehavior = .none
            dying?.close()
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DebugLog.write("localMonitor keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") flags=\(event.modifierFlags.rawValue) isKey=\(self?.window?.isKeyWindow ?? false)")
            if self?.view?.handleKey(event) == true {
                DebugLog.write("localMonitor consumed keyCode=\(event.keyCode)")
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func saveAndClose() {
        guard finished == false else { return }
        finished = true
        let updated = view?.currentLayout
        let done = finish
        close()
        done(updated)
    }

    func cancelFromOutside() { cancel() }

    private func cancel() {
        guard finished == false else { return }
        finished = true
        let done = finish
        close()
        done(nil)
    }
}

final class CanvasEditView: NSView {
    private var layout: Layout
    private let screen: NSScreen
    private let onSave: () -> Void
    private let onCancel: () -> Void
    private var selected = 0
    private var dragKind: DragKind = .none
    private var dragStart = NSPoint.zero
    private var startZone = RelZone(x: 0, y: 0, w: 1, h: 1)
    private let saveButton = NSButton(title: "Save  (Enter)", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel  (Esc)", target: nil, action: nil)
    private let addButton = NSButton(title: "Add zone  (N)", target: nil, action: nil)
    var currentLayout: Layout { layout }

    private enum DragKind { case none, move, n, s, e, w, ne, nw, se, sw }

    init(frame: NSRect, layout: Layout, screen: NSScreen, save: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.layout = layout
        self.screen = screen
        self.onSave = save
        self.onCancel = cancel
        super.init(frame: frame)
        wantsLayer = true
        installButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        let settings = ZoneStore.shared.settings
        let spacing = settings.spaceAroundZones ? CGFloat(settings.zoneSpacing) : 0
        let work = Geometry.workArea(for: screen, spanAll: false)
        for (idx, zone) in layout.zones.enumerated() {
            let global = Geometry.zoneFrame(zone, in: work, spacing: spacing, applySpacing: settings.spaceAroundZones)
            let local = convertFromScreen(global)
            let path = NSBezierPath(roundedRect: local.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            let active = idx == selected
            FZColor.hex(settings.highlightHex, alpha: active ? 0.45 : 0.22).setFill()
            path.fill()
            FZColor.hex(settings.highlightHex, alpha: active ? 1 : 0.5).setStroke()
            path.lineWidth = active ? 3 : 1.5
            path.stroke()
            ("\(idx + 1)" as NSString).draw(
                at: NSPoint(x: local.midX - 8, y: local.midY - 10),
                withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white]
            )
            if active {
                for handle in handles(in: local) {
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: handle.1).fill()
                }
            }
        }
        drawChrome()
    }

    private func installButtons() {
        for button in [saveButton, cancelButton, addButton] {
            button.bezelStyle = .rounded
            button.setButtonType(.momentaryPushIn)
            button.target = self
        }
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        saveButton.contentTintColor = .controlAccentColor
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        addButton.action = #selector(addTapped)
        for button in [saveButton, cancelButton, addButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36).isActive = true
        }
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            addButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40)
        ])
    }

    @objc private func saveTapped() { onSave() }
    @objc private func cancelTapped() { onCancel() }
    @objc private func addTapped() { addZone() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let settings = ZoneStore.shared.settings
        let spacing = settings.spaceAroundZones ? CGFloat(settings.zoneSpacing) : 0
        let work = Geometry.workArea(for: screen, spanAll: false)
        if layout.zones.indices.contains(selected) {
            let global = Geometry.zoneFrame(layout.zones[selected], in: work, spacing: spacing, applySpacing: settings.spaceAroundZones)
            let local = convertFromScreen(global)
            for (kind, rect) in handles(in: local) where rect.contains(p) {
                dragKind = kind
                dragStart = p
                startZone = layout.zones[selected]
                return
            }
        }
        for (idx, zone) in layout.zones.enumerated().reversed() {
            let global = Geometry.zoneFrame(zone, in: work, spacing: spacing, applySpacing: settings.spaceAroundZones)
            if convertFromScreen(global).contains(p) {
                selected = idx
                dragKind = .move
                dragStart = p
                startZone = zone
                needsDisplay = true
                return
            }
        }
        dragKind = .none
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragKind != .none, layout.zones.indices.contains(selected) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Double((p.x - dragStart.x) / screen.visibleFrame.width)
        let dy = Double((dragStart.y - p.y) / screen.visibleFrame.height)
        var z = startZone
        switch dragKind {
        case .move:
            z.x += dx; z.y += dy
        case .e:
            z.w += dx
        case .w:
            z.x += dx; z.w -= dx
        case .s:
            z.h += dy
        case .n:
            z.y += dy; z.h -= dy
        case .se:
            z.w += dx; z.h += dy
        case .sw:
            z.x += dx; z.w -= dx; z.h += dy
        case .ne:
            z.w += dx; z.y += dy; z.h -= dy
        case .nw:
            z.x += dx; z.y += dy; z.w -= dx; z.h -= dy
        case .none:
            break
        }
        layout.zones[selected] = z.clamped()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragKind = .none
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: Double = flags.contains(.control) ? 0.002 : 0.01
        let code = Int(event.keyCode)
        DebugLog.write("handleKey code=\(code) chars=\(event.charactersIgnoringModifiers ?? "") winKey=\(window?.isKeyWindow ?? false) first=\(String(describing: window?.firstResponder))")
        if code == kVK_Escape {
            onCancel()
            return true
        }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            onSave()
            return true
        }
        if code == kVK_ANSI_S && flags.contains(.command) {
            onSave()
            return true
        }
        if code == kVK_ANSI_N {
            addZone()
            return true
        }
        if code == kVK_Delete || code == kVK_ForwardDelete {
            deleteSelected()
            return true
        }
        if code == kVK_Tab {
            if layout.zones.isEmpty == false {
                let delta = flags.contains(.shift) ? -1 : 1
                selected = (selected + delta + layout.zones.count) % layout.zones.count
                needsDisplay = true
            }
            return true
        }
        guard layout.zones.indices.contains(selected) else { return false }
        var z = layout.zones[selected]
        let resize = flags.contains(.shift)
        switch code {
        case kVK_LeftArrow:
            if resize { z.w = max(0.04, z.w - step) } else { z.x -= step }
        case kVK_RightArrow:
            if resize { z.w += step } else { z.x += step }
        case kVK_UpArrow:
            if resize { z.h = max(0.04, z.h - step) } else { z.y -= step }
        case kVK_DownArrow:
            if resize { z.h += step } else { z.y += step }
        default:
            return false
        }
        layout.zones[selected] = z.clamped()
        needsDisplay = true
        return true
    }

    private func addZone() {
        layout.zones.append(RelZone(x: 0.2, y: 0.2, w: 0.35, h: 0.35))
        selected = layout.zones.count - 1
        layout.zoneCount = layout.zones.count
        needsDisplay = true
    }

    private func deleteSelected() {
        guard layout.zones.count > 1, layout.zones.indices.contains(selected) else { return }
        layout.zones.remove(at: selected)
        selected = min(selected, layout.zones.count - 1)
        layout.zoneCount = layout.zones.count
        needsDisplay = true
    }

    private func convertFromScreen(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func handles(in rect: CGRect) -> [(DragKind, CGRect)] {
        let s: CGFloat = 12
        return [
            (.nw, CGRect(x: rect.minX - s/2, y: rect.maxY - s/2, width: s, height: s)),
            (.n, CGRect(x: rect.midX - s/2, y: rect.maxY - s/2, width: s, height: s)),
            (.ne, CGRect(x: rect.maxX - s/2, y: rect.maxY - s/2, width: s, height: s)),
            (.e, CGRect(x: rect.maxX - s/2, y: rect.midY - s/2, width: s, height: s)),
            (.se, CGRect(x: rect.maxX - s/2, y: rect.minY - s/2, width: s, height: s)),
            (.s, CGRect(x: rect.midX - s/2, y: rect.minY - s/2, width: s, height: s)),
            (.sw, CGRect(x: rect.minX - s/2, y: rect.minY - s/2, width: s, height: s)),
            (.w, CGRect(x: rect.minX - s/2, y: rect.midY - s/2, width: s, height: s))
        ]
    }

    private func drawChrome() {
        let bar = CGRect(x: 24, y: 24, width: bounds.width - 48, height: 72)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 12, yRadius: 12).fill()
        let text = "Drag zones to move  ·  drag handles to resize  ·  arrows nudge  ·  Shift+arrows resize  ·  Delete remove"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let drawRect = CGRect(x: bar.minX + 16, y: bar.minY + 46, width: bar.width - 32, height: 20)
        (text as NSString).draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}
