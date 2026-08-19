import AppKit
import Carbon.HIToolbox

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
        previewTarget = NSScreen.main ?? Geometry.primary
        OverlayController.shared.show(
            highlighted: [],
            cursor: NSPoint(x: previewTarget.frame.midX, y: previewTarget.frame.midY),
            forceAllMonitors: false,
            layoutOverride: ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: previewTarget)),
            monitorOverride: previewTarget
        )
        showPanel()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        isOpen = false
        isEditingCanvas = false
        canvasSession?.close()
        canvasSession = nil
        panel?.orderOut(nil)
        panel = nil
        OverlayController.shared.hide()
    }

    func windowWillClose(_ notification: Notification) {
        if isEditingCanvas == false {
            close()
        }
    }

    private func showPanel() {
        let width: CGFloat = 520
        let height: CGFloat = 640
        let screen = previewTarget
        let rect = NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Snaplane Layout Editor"
        panel.isFloatingPanel = true
        panel.level = .floating
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

        for view in [title, hint, monitorPop, countLabel, countField, stepper, spaceLabel, spacing, hotLabel, hotkeyPop, scroll, apply, edit, del, canvas, grid, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            monitorPop.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            monitorPop.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            monitorPop.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            countLabel.topAnchor.constraint(equalTo: monitorPop.bottomAnchor, constant: 12),
            countLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            countField.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            countField.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 8),
            countField.widthAnchor.constraint(equalToConstant: 44),

            stepper.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            stepper.leadingAnchor.constraint(equalTo: countField.trailingAnchor, constant: 4),

            spaceLabel.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            spaceLabel.leadingAnchor.constraint(equalTo: stepper.trailingAnchor, constant: 20),

            spacing.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            spacing.leadingAnchor.constraint(equalTo: spaceLabel.trailingAnchor, constant: 8),
            spacing.widthAnchor.constraint(equalToConstant: 90),

            hotLabel.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            hotLabel.leadingAnchor.constraint(equalTo: spacing.trailingAnchor, constant: 12),
            hotkeyPop.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            hotkeyPop.leadingAnchor.constraint(equalTo: hotLabel.trailingAnchor, constant: 6),
            hotkeyPop.trailingAnchor.constraint(lessThanOrEqualTo: title.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: apply.topAnchor, constant: -12),

            canvas.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            grid.leadingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: 8),
            grid.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),

            done.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            done.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            apply.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            apply.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            del.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -8),
            del.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            edit.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -8),
            edit.centerYAnchor.constraint(equalTo: canvas.centerYAnchor)
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
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
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

    init(layout: Layout, screen: NSScreen, finish: @escaping (Layout?) -> Void) {
        self.layout = layout
        self.screen = screen
        self.finish = finish
    }

    func start() {
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false
        win.delegate = self
        let view = CanvasEditView(frame: screen.frame, layout: layout, screen: screen) { [weak self] in
            self?.saveAndClose()
        } cancel: { [weak self] in
            self?.cancel()
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
        self.view = view
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func saveAndClose() {
        if let updated = view?.currentLayout {
            let done = finish
            close()
            done(updated)
        } else {
            cancel()
        }
    }

    private func cancel() {
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
    var currentLayout: Layout { layout }

    private enum DragKind { case none, move, n, s, e, w, ne, nw, se, sw }

    init(frame: NSRect, layout: Layout, screen: NSScreen, save: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.layout = layout
        self.screen = screen
        self.onSave = save
        self.onCancel = cancel
        super.init(frame: frame)
        wantsLayer = true
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
        let flags = event.modifierFlags
        let step: Double = flags.contains(.control) ? 0.002 : 0.01
        if event.keyCode == UInt16(kVK_Escape) { onCancel(); return }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_S) && flags.contains(.command) {
            onSave(); return
        }
        if event.charactersIgnoringModifiers == "n" || event.charactersIgnoringModifiers == "N" {
            addZone(); return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            deleteSelected(); return
        }
        guard layout.zones.indices.contains(selected) else { return }
        var z = layout.zones[selected]
        let resize = flags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            if resize { z.w = max(0.04, z.w - step) } else { z.x -= step }
        case kVK_RightArrow:
            if resize { z.w += step } else { z.x += step }
        case kVK_UpArrow:
            if resize { z.h = max(0.04, z.h - step) } else { z.y -= step }
        case kVK_DownArrow:
            if resize { z.h += step } else { z.y += step }
        default:
            super.keyDown(with: event)
            return
        }
        layout.zones[selected] = z.clamped()
        needsDisplay = true
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
        let bar = CGRect(x: 24, y: 24, width: bounds.width - 48, height: 52)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 12, yRadius: 12).fill()
        let text = "Canvas editor  ·  drag to move  ·  handles resize  ·  N add  ·  Delete remove  ·  arrows nudge  ·  Enter save  ·  Esc cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        (text as NSString).draw(at: NSPoint(x: 40, y: 40), withAttributes: attrs)
    }
}
