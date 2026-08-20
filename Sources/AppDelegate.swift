import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var accessibilityTimer: Timer?
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashCatch.install()
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self

        buildStatusItem()
        observe()

        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        if ZoneStore.shared.settings.launchAtLogin {
            LaunchAtLogin.ensureInstalled()
        }

        logIdentity()
        startEngine()
        Watchdog.shared.start()
        if CommandLine.arguments.contains("--debug-canvas") {
            DebugLog.write("launch --debug-canvas pid=\(ProcessInfo.processInfo.processIdentifier)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                DebugLog.dumpWindows("pre-canvas")
                let screen = NSScreen.main ?? Geometry.primary
                let current = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: screen))
                EditorController.shared.openCanvasEditor(current)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    DebugLog.dumpWindows("post-canvas")
                }
            }
            return
        }
        if WindowAX.isTrusted(prompt: false) {
            if !UserDefaults.standard.bool(forKey: "FZDidShowWelcome") {
                showWelcome()
            }
        } else {
            showAccessibilityHelp()
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.startEngine()
                if WindowAX.isTrusted(prompt: false) {
                    self?.accessibilityTimer?.invalidate()
                    self?.accessibilityTimer = nil
                    self?.welcome?.orderOut(nil)
                    if !UserDefaults.standard.bool(forKey: "FZDidShowWelcome") {
                        self?.showWelcome()
                    }
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        EditorController.shared.open()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Watchdog.shared.stop()
        DragMonitor.shared.stop()
        HotkeyCenter.shared.stop()
        OverlayController.shared.hide()
        SLLog.line("terminate")
    }

    private func startEngine() {
        DragMonitor.shared.start()
        HotkeyCenter.shared.start()
        rebuildMenu()
    }

    private func logIdentity() {
        SLLog.line("launch bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath) ax=\(WindowAX.isTrusted(prompt: false)) listen=\(CGPreflightListenEventAccess()) agent=\(LaunchAtLogin.isLoaded())")
    }

    private func observe() {
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMenu), name: .fzLayoutsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMenu), name: .fzSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enabledChanged), name: .fzEnabledChanged, object: nil)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Snapper.reflowSnappedWindows(layoutChanged: false)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == WindowAX.ownPID { return }
            Snapper.placeNewWindow(for: app)
        }
    }

    @objc private func enabledChanged() {
        if ZoneStore.shared.settings.enabled {
            DragMonitor.shared.start()
        } else {
            DragMonitor.shared.stop()
            OverlayController.shared.hide()
        }
        rebuildMenu()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.split.3x3", accessibilityDescription: "Snaplane")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Snaplane"
        }
        statusItem = item
        rebuildMenu()
    }

    @objc private func rebuildMenu() {
        let menu = NSMenu()
        let enabled = ZoneStore.shared.settings.enabled
        let toggle = NSMenuItem(
            title: enabled ? "Snaplane is On" : "Snaplane is Off",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggle.state = enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        let ax = WindowAX.isTrusted(prompt: false)
        if !ax {
            let item = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let editor = NSMenuItem(title: "Open Layout Editor", action: #selector(openEditor), keyEquivalent: "`")
        editor.keyEquivalentModifierMask = [.control, .option, .shift]
        editor.target = self
        menu.addItem(editor)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.control, .option, .shift]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let layouts = NSMenu(title: "Layouts")
        let screen = NSScreen.main ?? Geometry.primary
        let currentId = ZoneStore.shared.layout(forMonitorKey: Geometry.monitorKey(for: screen)).id
        for layout in ZoneStore.shared.layouts {
            let item = NSMenuItem(title: layout.name, action: #selector(pickLayout(_:)), keyEquivalent: "")
            item.representedObject = layout.id
            item.state = layout.id == currentId ? .on : .off
            item.target = self
            if let hot = layout.hotkey {
                item.title = "\(layout.name)  (⌃⌥⌘\(hot))"
            }
            layouts.addItem(item)
        }
        let layoutsItem = NSMenuItem(title: "Current layout", action: nil, keyEquivalent: "")
        layoutsItem.submenu = layouts
        menu.addItem(layoutsItem)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login (Keep Alive)", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = ZoneStore.shared.settings.launchAtLogin ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        if let button = statusItem?.button {
            button.appearsDisabled = !enabled
        }
    }

    @objc private func toggleEnabled() {
        ZoneStore.shared.updateSettings { $0.enabled.toggle() }
        enabledChanged()
    }

    @objc private func openEditor() { EditorController.shared.open() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func pickLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let screen = NSScreen.main ?? Geometry.primary
        ZoneStore.shared.assign(layoutId: id, toMonitorKey: Geometry.monitorKey(for: screen))
        if let layout = ZoneStore.shared.layouts.first(where: { $0.id == id }),
           ZoneStore.shared.settings.flashZonesOnSwitch {
            OverlayController.shared.flash(layout: layout, on: screen)
        }
        Snapper.reflowSnappedWindows(layoutChanged: true)
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        let next = !ZoneStore.shared.settings.launchAtLogin
        ZoneStore.shared.updateSettings { $0.launchAtLogin = next }
        LaunchAtLogin.setEnabled(next)
        rebuildMenu()
    }

    @objc private func stopUntilLogin() {
        LaunchAtLogin.stopUntilNextLogin()
    }

    @objc private func quitApp() {
        LaunchAtLogin.stopUntilNextLogin()
    }

    @objc private func openAccessibility() {
        _ = WindowAX.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAccessibilityHelp() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Snaplane needs Accessibility"
        win.animationBehavior = .none
        win.center()
        let view = NSView(frame: win.contentView!.bounds)
        let text = NSTextField(wrappingLabelWithString: "Snaplane needs Accessibility to move and resize windows.\n\n1. Open System Settings → Privacy & Security → Accessibility\n2. Enable Snaplane\n3. This window closes by itself once permission is granted.")
        text.frame = NSRect(x: 20, y: 70, width: 480, height: 140)
        let button = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibility))
        button.frame = NSRect(x: 140, y: 20, width: 240, height: 32)
        view.addSubview(text)
        view.addSubview(button)
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcome = win
    }

    private func showWelcome() {
        UserDefaults.standard.set(true, forKey: "FZDidShowWelcome")
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Snaplane is running"
        win.animationBehavior = .none
        win.center()
        let text = NSTextField(wrappingLabelWithString: "Snaplane lives in the menu bar and stays on after restarts.\n\n• Hold Shift and drag a window — drop it on a highlighted zone\n• ⌃⌥ arrows snap the focused window between zones\n• ⌃⌥⇧` opens the layout editor\n\nTurn off Rectangle / MacsyZones while using this, or their shortcuts will fight.")
        text.frame = NSRect(x: 20, y: 60, width: 480, height: 170)
        let button = NSButton(title: "Open Layout Editor", target: self, action: #selector(openEditor))
        button.frame = NSRect(x: 160, y: 16, width: 200, height: 32)
        let view = NSView(frame: win.contentView!.bounds)
        view.addSubview(text)
        view.addSubview(button)
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
