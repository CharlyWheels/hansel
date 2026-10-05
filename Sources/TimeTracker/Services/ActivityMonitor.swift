import Foundation
import AppKit
import SwiftData
import ApplicationServices

/// Passively samples the frontmost app every 30 s (and on activation events).
/// For known browsers, queries the active-tab URL + title via AppleScript.
/// Uses the AX API for window titles on non-browser apps when Accessibility is granted.
@MainActor
final class ActivityMonitor {
    private let modelContext: ModelContext
    private weak var idleMonitor: IdleMonitor?
    /// Set after construction — the detector needs this monitor's samples in turn, so
    /// the two are wired together rather than one owning the other.
    weak var meetingDetector: MeetingDetector?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastSample: ActivitySample?

    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser" // Arc
    ]

    init(modelContext: ModelContext, idleMonitor: IdleMonitor? = nil) {
        self.modelContext = modelContext
        self.idleMonitor = idleMonitor
    }

    func bind(idleMonitor: IdleMonitor) {
        self.idleMonitor = idleMonitor
    }

    func start() {
        stop()
        sample()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        AppLogger.activity.info("ActivityMonitor started")
        AppLogger.log("activity", level: .info, "start")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activationObserver = nil
        }
    }

    // MARK: - Sampling

    private func sample() {
        // Skip sampling while the system is idle or the screen is locked — otherwise
        // we log phantom frontmost-app activity (loginwindow, NotificationCenter) that
        // would later trigger the AI watchdog.
        if idleMonitor?.isIdle == true {
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "Unknown"

        var windowTitle: String? = axFocusedWindowTitle(pid: app.processIdentifier)
        var url: String?

        if browserBundleIDs.contains(bundleId) {
            let pair = browserURLAndTitle(bundleId: bundleId)
            if pair.url?.isEmpty == false { url = pair.url }
            if let t = pair.title, !t.isEmpty { windowTitle = t }
        }

        let flags = currentFlags(bundleId: bundleId, windowTitle: windowTitle, url: url)

        if let last = lastSample,
           last.bundleId == bundleId,
           last.windowTitle == windowTitle,
           last.url == url,
           last.flags == flags,
           Date().timeIntervalSince(last.timestamp) < 25 {
            return
        }

        let sample = ActivitySample(
            timestamp: Date(),
            bundleId: bundleId,
            appName: appName,
            windowTitle: windowTitle,
            url: url,
            flags: flags
        )
        modelContext.insert(sample)
        lastSample = sample
        do {
            try modelContext.save()
            AppLogger.activity.debug("sample bundle=\(bundleId, privacy: .public) title=\(windowTitle ?? "-", privacy: .public)")
        } catch {
            AppLogger.activity.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Signals attached to this instant, so the segmenter can weigh "was I on a call"
    /// as part of the context rather than needing a live service at scoring time.
    private func currentFlags(bundleId: String, windowTitle: String?, url: String?) -> SignalFlags {
        var flags: SignalFlags = []
        let inMeeting = meetingDetector?.state.isInMeeting == true
        if inMeeting {
            flags.insert(.micActive)
        }
        if ConferenceCatalog.isConferenceApp(bundleId) {
            // Zoom sitting open in the background is not a call. An explicit "idle"
            // title vetoes the flag. For apps whose title never says (Teams, Slack,
            // Discord) the app being in front proves nothing — it is usually chat —
            // so only the microphone can confirm the call.
            switch ConferenceCatalog.titleIndicatesCall(bundleId: bundleId, windowTitle: windowTitle) {
            case true?: flags.insert(.videoCallApp)
            case nil where inMeeting: flags.insert(.videoCallApp)
            default: break
            }
        }
        if ConferenceCatalog.isConferenceURL(url) { flags.insert(.conferenceURL) }
        return flags
    }

    // MARK: - AX window title

    private func axFocusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return nil }
        let window = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }

    // MARK: - AppleScript (browsers)

    private func browserURLAndTitle(bundleId: String) -> (url: String?, title: String?) {
        let script: String?
        switch bundleId {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
                if (count of windows) is 0 then return {"", ""}
                try
                    set theURL to URL of current tab of front window
                    set theTitle to name of current tab of front window
                    return {theURL, theTitle}
                on error
                    return {"", ""}
                end try
            end tell
            """
        case "com.google.Chrome",
             "com.brave.Browser",
             "company.thebrowser.Browser",
             "com.microsoft.edgemac":
            let appName: String
            switch bundleId {
            case "com.google.Chrome": appName = "Google Chrome"
            case "com.brave.Browser": appName = "Brave Browser"
            case "company.thebrowser.Browser": appName = "Arc"
            case "com.microsoft.edgemac": appName = "Microsoft Edge"
            default: appName = "Google Chrome"
            }
            script = """
            tell application "\(appName)"
                if (count of windows) is 0 then return {"", ""}
                try
                    set theURL to URL of active tab of front window
                    set theTitle to title of active tab of front window
                    return {theURL, theTitle}
                on error
                    return {"", ""}
                end try
            end tell
            """
        default:
            script = nil
        }
        guard let source = script, let apple = NSAppleScript(source: source) else {
            return (nil, nil)
        }
        var errorInfo: NSDictionary?
        let result = apple.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            AppLogger.activity.debug("AppleScript \(bundleId, privacy: .public) error=\(String(describing: err), privacy: .public)")
            return (nil, nil)
        }
        guard result.numberOfItems == 2 else { return (nil, nil) }
        let urlStr = result.atIndex(1)?.stringValue
        let titleStr = result.atIndex(2)?.stringValue
        return (urlStr, titleStr)
    }
}
