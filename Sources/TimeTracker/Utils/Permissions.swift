import Foundation
import AppKit
import EventKit
import ApplicationServices
import CoreServices

enum PermissionStatus: String {
    case granted
    case denied
    case unknown
    case notInstalled
}

struct BrowserTarget: Identifiable, Hashable {
    let bundleID: String
    let displayName: String
    var id: String { bundleID }

    static let all: [BrowserTarget] = [
        .init(bundleID: "com.apple.Safari", displayName: "Safari"),
        .init(bundleID: "com.google.Chrome", displayName: "Google Chrome"),
        .init(bundleID: "company.thebrowser.Browser", displayName: "Arc"),
        .init(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge"),
        .init(bundleID: "com.brave.Browser", displayName: "Brave")
    ]
}

/// Checks and prompts for the three permissions the app needs.
/// Phase 2 wires these into the Permissions settings pane.
enum Permissions {

    // MARK: - Accessibility (window titles via AX API)

    static func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Opens the Accessibility pane. macOS does not allow prompting directly.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Calendar (EventKit)

    static func calendarStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }

    static func requestCalendarAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            AppLogger.calendar.error("requestFullAccessToEvents failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Automation (AppleScript — per-target bundle)

    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    /// True if the browser app is installed on this Mac.
    static func isBrowserInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Queries macOS whether we have permission to send AppleEvents to `bundleID`
    /// without prompting. Returns `.granted` / `.denied` / `.unknown` / `.notInstalled`.
    static func automationStatus(forBundleID bundleID: String) -> PermissionStatus {
        guard isBrowserInstalled(bundleID) else { return .notInstalled }
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let addr = targetDescriptor.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(addr, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case -1744 /* errAEEventWouldRequireUserConsent */: return .unknown
        default: return .unknown
        }
    }

    /// Triggers the one-time Automation prompt for a given browser by actually sending it
    /// a no-op AppleEvent. Used by the "Test" button in the Permissions pane.
    static func promptAutomationForBrowser(_ bundleID: String) {
        let appName: String
        switch bundleID {
        case "com.apple.Safari": appName = "Safari"
        case "com.google.Chrome": appName = "Google Chrome"
        case "com.brave.Browser": appName = "Brave Browser"
        case "company.thebrowser.Browser": appName = "Arc"
        case "com.microsoft.edgemac": appName = "Microsoft Edge"
        default: return
        }
        let source = "tell application \"\(appName)\" to count of windows"
        guard let script = NSAppleScript(source: source) else { return }
        var err: NSDictionary?
        _ = script.executeAndReturnError(&err)
    }
}
