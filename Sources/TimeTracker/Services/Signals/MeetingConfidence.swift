import Foundation

/// One observation supporting or opposing "the user is in a meeting right now".
struct MeetingEvidence: Equatable, Sendable, Codable {
    let signal: String
    let detail: String
    let weight: Double
}

/// The raw observations, gathered by `MeetingDetector` and scored here.
/// Kept as a plain value type so the scoring is unit-testable without CoreAudio.
struct MeetingSignals: Equatable, Sendable {
    var micActive: Bool = false
    /// Bundle ids attributed to audio input, or nil when the OS won't tell us.
    /// nil means "unknown", never "nobody".
    var micBundleIds: Set<String>? = nil
    var cameraActive: Bool = false
    var runningConferenceApps: [String] = []
    /// A conference app's window title indicates a call actually in progress.
    var callTitleMatch: Bool = false
    var conferenceURLSeen: Bool = false
    var vetoAppActive: Bool = false
    /// A calendar event that passed `AttendanceFilter` is in progress right now.
    var trustworthyMeetingInProgress: Bool = false
    /// Meeting Notes is recording right now.
    var recordingActive: Bool = false
    /// The recording itself, so the meeting can be named after it.
    var recording: ActiveRecording? = nil
    /// Screen locked or Mac asleep. Plain keyboard inactivity is deliberately not
    /// included: listening on a call without typing is the normal case, and counting
    /// it against the call made a quiet meeting drop out of the meeting state.
    var isIdleOrLocked: Bool = false
}

/// Turns observations into a 0…1 confidence, with the hysteresis thresholds that stop
/// the state flapping between "in a meeting" and "not" every few seconds.
enum MeetingConfidence {

    /// Confidence must reach this, twice in a row, to enter the meeting state.
    static let enterThreshold = 0.70
    /// It must stay below this for `exitSustainSeconds` to leave.
    static let exitThreshold = 0.40
    static let exitSustainSeconds: TimeInterval = 60

    static func evaluate(_ signals: MeetingSignals) -> (confidence: Double, evidence: [MeetingEvidence]) {
        var evidence: [MeetingEvidence] = []
        var score = 0.0

        if signals.micActive {
            // Attribution, when the OS provides it, is far stronger than a bare device
            // read: it distinguishes Zoom from a podcast recorder.
            let attributed = signals.micBundleIds?.lazy.compactMap(ConferenceCatalog.owningApp).first
            if let attributed {
                score += 0.75
                evidence.append(.init(signal: "mic.process", detail: attributed.displayName, weight: 0.75))
            } else {
                score += 0.45
                evidence.append(.init(signal: "mic", detail: "input device active", weight: 0.45))
            }
        }

        // Microphone and camera together are a video call.
        if signals.cameraActive {
            score += 0.25
            evidence.append(.init(signal: "camera", detail: "camera on", weight: 0.25))
        }

        // The user pressed Record in Meeting Notes: they are in a meeting by their own
        // account, which no app or calendar heuristic can beat.
        if signals.recordingActive {
            score += 0.50
            evidence.append(.init(signal: "recording", detail: "recording the meeting", weight: 0.50))
        }

        if let app = signals.runningConferenceApps.first {
            score += 0.15
            let name = ConferenceCatalog.app(forBundleId: app)?.displayName ?? app
            evidence.append(.init(signal: "app.running", detail: name, weight: 0.15))
        }

        if signals.callTitleMatch {
            score += 0.35
            evidence.append(.init(signal: "app.window", detail: "in-call window title", weight: 0.35))
        }

        if signals.conferenceURLSeen {
            score += 0.30
            evidence.append(.init(signal: "url", detail: "conference URL open", weight: 0.30))
        }

        if signals.trustworthyMeetingInProgress {
            score += 0.25
            evidence.append(.init(signal: "calendar", detail: "event in progress", weight: 0.25))
        }

        // Vetoes. A podcast, a screen recording or a dictation session holds the
        // microphone exactly like a meeting does.
        if signals.vetoAppActive {
            score -= 0.40
            evidence.append(.init(signal: "veto.app", detail: "recording or media app active", weight: -0.40))
        }
        if signals.isIdleOrLocked {
            score -= 0.25
            evidence.append(.init(signal: "veto.idle", detail: "screen locked or asleep", weight: -0.25))
        }

        return (Similarity.clamp01(score), evidence)
    }
}

/// The detector's published view of the world.
struct MeetingState: Equatable, Sendable {
    var isInMeeting: Bool = false
    /// Back-dated to when the microphone actually opened, not when we noticed.
    var since: Date? = nil
    var appBundleId: String? = nil
    var appName: String? = nil
    var confidence: Double = 0
    var evidence: [MeetingEvidence] = []
    /// A Meeting Notes recording in progress, refreshed on every evaluation so a new
    /// recording during a running call (back-to-back meetings) is seen at once.
    var recording: ActiveRecording? = nil
    /// When the last call ended: the microphone closing, not when we noticed.
    var endedAt: Date? = nil

    var summary: String {
        evidence.filter { $0.weight > 0 }.map(\.detail).joined(separator: " · ")
    }
}
