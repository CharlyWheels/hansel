import Foundation
import AppKit
import ApplicationServices

/// Decides whether the user is actually in a meeting right now.
///
/// This is the signal the tracker never had. Without it the app could only guess from
/// the calendar, which is why a declined invitation could start a timer while a real,
/// unscheduled call went unnoticed.
///
/// Gathering deliberately does NOT rely on `ActivitySample` alone. That stream records
/// only the frontmost app and the active tab of the front window, and during a meeting
/// the user usually has notes or a browser in front — so the meeting app never appears
/// in it. Running-app enumeration and targeted window queries fill that gap, and both
/// are gated on the microphone being open so they cost nothing at idle.
@MainActor
final class MeetingDetector {

    private(set) var state = MeetingState()
    var onChange: ((MeetingState, MeetingState) -> Void)?

    private let audio: AudioInputMonitor
    private weak var idleMonitor: IdleMonitor?
    /// Supplies conference URLs seen recently and any in-progress trustworthy event.
    var recentConferenceURL: () -> Bool = { false }
    var trustworthyMeetingInProgress: () -> Bool = { false }
    var cameraActive: () -> Bool = { CameraActivity.isAnyCameraRunning() }

    private var pollTimer: Timer?
    /// Confidence must clear the entry threshold twice running before we commit.
    private var consecutiveAboveEnter = 0
    private var belowExitSince: Date?

    init(audio: AudioInputMonitor, idleMonitor: IdleMonitor?) {
        self.audio = audio
        self.idleMonitor = idleMonitor
    }

    func start() {
        audio.onChange = { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // While the microphone is closed there is nothing to track, so the timer only
        // does real work during a call; the cheap early-out keeps it near-free.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
        AppLogger.activity.info("MeetingDetector started")
        AppLogger.log("activity", level: .info, "meeting_detector_start")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Evaluation

    func evaluate() {
        let signals = gather()
        let (confidence, evidence) = MeetingConfidence.evaluate(signals)
        let previous = state
        if signals.micActive && !state.isInMeeting {
            AppLogger.log(
                "activity", level: .debug,
                "meeting_eval confidence=\(String(format: "%.2f", confidence)) evidence=\(evidence.map { "\($0.signal)=\($0.weight)" }.joined(separator: ","))"
            )
        }

        if state.isInMeeting {
            if confidence < MeetingConfidence.exitThreshold {
                let since = belowExitSince ?? Date()
                belowExitSince = since
                // Some apps release the input device on mute, so a dip is weak evidence
                // that the call ended. Require it to persist.
                if Date().timeIntervalSince(since) >= MeetingConfidence.exitSustainSeconds {
                    // The call ended when the microphone closed, not a minute later
                    // when the dip had lasted long enough to believe.
                    let endedAt = signals.micActive ? since : min(since, audio.changedAt)
                    state = MeetingState(
                        isInMeeting: false, confidence: confidence, evidence: evidence,
                        endedAt: endedAt
                    )
                    belowExitSince = nil
                    consecutiveAboveEnter = 0
                    publish(previous)
                    return
                }
            } else {
                belowExitSince = nil
            }
            state.confidence = confidence
            state.evidence = evidence
            return
        }

        if confidence >= MeetingConfidence.enterThreshold {
            consecutiveAboveEnter += 1
            if consecutiveAboveEnter >= 2 {
                let app = signals.runningConferenceApps.first
                state = MeetingState(
                    isInMeeting: true,
                    // Back-date to when the microphone opened so the entry boundary is
                    // honest rather than however late we happened to notice.
                    since: signals.micActive ? audio.changedAt : Date(),
                    appBundleId: app,
                    appName: app.flatMap { ConferenceCatalog.app(forBundleId: $0)?.displayName },
                    confidence: confidence,
                    evidence: evidence
                )
                publish(previous)
                return
            }
        } else {
            consecutiveAboveEnter = 0
        }
        state.confidence = confidence
        state.evidence = evidence
    }

    private func publish(_ previous: MeetingState) {
        AppLogger.activity.info(
            "Meeting state → \(self.state.isInMeeting ? "in meeting" : "not in meeting", privacy: .public) confidence=\(self.state.confidence, privacy: .public)"
        )
        AppLogger.log(
            "activity", level: .info,
            "meeting_state in=\(state.isInMeeting) confidence=\(String(format: "%.2f", state.confidence)) evidence=\(state.summary)"
        )
        onChange?(previous, state)
    }

    // MARK: - Gathering

    private func gather() -> MeetingSignals {
        var signals = MeetingSignals()
        signals.micActive = audio.isCapturing
        // Only a lock or sleep says the user left. Not typing during a call is normal.
        signals.isIdleOrLocked = idleMonitor.map { $0.isScreenLocked || $0.isAsleep } ?? false

        // Everything below is only meaningful while something is capturing, so skip it
        // entirely otherwise — this is what keeps the 20 s timer free at idle.
        guard signals.micActive || signals.isIdleOrLocked == false else { return signals }

        let running = NSWorkspace.shared.runningApplications
        let runningBundleIds = running.compactMap(\.bundleIdentifier)

        signals.micBundleIds = audio.capturingBundleIDs()
        signals.cameraActive = cameraActive()
        signals.runningConferenceApps = runningBundleIds.filter(ConferenceCatalog.isConferenceApp)

        // A veto app counts if it currently holds the microphone, or is frontmost.
        let vetoHoldsMic = signals.micBundleIds?.contains(where: ConferenceCatalog.isVetoApp) ?? false
        let vetoFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .map(ConferenceCatalog.isVetoApp) ?? false
        signals.vetoAppActive = vetoHoldsMic || vetoFrontmost

        if signals.micActive {
            signals.callTitleMatch = anyConferenceWindowIndicatesCall(
                running: running,
                conferenceBundleIds: Set(signals.runningConferenceApps)
            )
        }
        signals.conferenceURLSeen = recentConferenceURL()
        signals.trustworthyMeetingInProgress = trustworthyMeetingInProgress()
        return signals
    }

    /// Asks the Accessibility API for the window titles of conference apps specifically,
    /// rather than waiting for one to become frontmost.
    ///
    /// A messaging timeout is essential: an unresponsive app would otherwise block the
    /// main thread for the AX default of several seconds.
    private func anyConferenceWindowIndicatesCall(
        running: [NSRunningApplication],
        conferenceBundleIds: Set<String>
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        for app in running {
            guard let bundleId = app.bundleIdentifier,
                  conferenceBundleIds.contains(bundleId) else { continue }
            guard let catalogApp = ConferenceCatalog.app(forBundleId: bundleId) else { continue }
            if catalogApp.runningImpliesCall { return true }
            guard catalogApp.windowTitleIsReliable else { continue }

            for title in windowTitles(pid: app.processIdentifier) {
                if ConferenceCatalog.titleIndicatesCall(bundleId: bundleId, windowTitle: title) == true {
                    return true
                }
            }
        }
        return false
    }

    private func windowTitles(pid: pid_t) -> [String] {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXWindowsAttribute as CFString, &value
        ) == .success, let windows = value as? [AXUIElement] else { return [] }

        return windows.prefix(8).compactMap { window in
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &titleRef
            ) == .success else { return nil }
            return titleRef as? String
        }
    }
}
