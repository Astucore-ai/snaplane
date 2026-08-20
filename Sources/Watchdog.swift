import AppKit
import CoreGraphics

final class Watchdog {
    static let shared = Watchdog()
    private var timer: Timer?

    private init() {}

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if ZoneStore.shared.settings.launchAtLogin {
            if !LaunchAtLogin.isLoaded() {
                SLLog.line("watchdog: LaunchAgent missing — reinstalling")
                LaunchAtLogin.install()
            }
        }
        if ZoneStore.shared.settings.enabled, WindowAX.isTrusted(prompt: false) {
            if !DragMonitor.shared.isTapInstalled {
                SLLog.line("watchdog: event tap missing — reinstalling")
                DragMonitor.shared.start()
            }
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }
}
