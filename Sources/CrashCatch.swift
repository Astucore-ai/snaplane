import Foundation

enum CrashCatch {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            SLLog.line("uncaught \(exception.name.rawValue): \(exception.reason ?? "")")
        }
    }
}
