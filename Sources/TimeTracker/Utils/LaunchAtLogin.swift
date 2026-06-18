import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp`. Only works when the app bundle lives
/// in `/Applications` (or another location macOS knows about). Running the dev build
/// from `build/` will not register — move `TimeTracker.app` into Applications first.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires approval in System Settings"
        case .notFound: return "Not found — move the app to /Applications"
        @unknown default: return "Unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            AppLogger.ui.info("LaunchAtLogin set to \(enabled)")
            AppLogger.log("ui", level: .info, "launch_at_login=\(enabled)")
        } catch {
            AppLogger.ui.error("LaunchAtLogin toggle failed: \(error.localizedDescription, privacy: .public)")
            AppLogger.log("ui", level: .error, "launch_at_login_failed: \(error.localizedDescription)")
        }
    }
}
