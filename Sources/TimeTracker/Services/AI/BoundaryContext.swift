import Foundation

/// Everything the model needs to adjudicate one proposed task boundary.
///
/// Note what this is *not*: it is not "here is some activity, tell me what it was".
/// The local signals have already proposed a specific instant and said why. The model's
/// job is to confirm or reject that hypothesis and, if it confirms, refine the instant.
struct BoundaryContext {
    /// The entry currently running, which the boundary would close.
    let currentEntry: EntryContext?
    /// Where the segmenter thinks the boundary sits, and how sure it is.
    let boundaryAt: Date
    let segmenterScore: Double
    let reasons: [BoundaryReason]

    /// Samples either side of the proposed boundary, already split.
    let before: [SignalSample]
    let after: [SignalSample]
    let idleSpans: [IdleSpan]
    let meeting: MeetingWindow?
    let meetingCorroborated: Bool

    /// Catalog for resolution, same shape the draft path uses.
    let projects: [Project]
    let customers: [Customer]
    let roles: [Role]
    let activeTodos: [Todo]
    let recentEntries: [TimeEntry]
    let ruleHints: RuleEngine.Hints
    /// Recent decisions the user rejected or corrected, as negative few-shots.
    let corrections: [BoundaryCorrectionExample]

    let now: Date
    /// The window `boundary_at` must fall inside; anything else is a hallucination.
    let earliestAllowed: Date
    let latestAllowed: Date
    /// The user's choices in Settings → AI about what may leave the Mac. Applies to
    /// this prompt exactly as it does to the draft prompt.
    var fields = ContextFieldSelection()
}

/// A past proposal and what the user actually wanted — the material that teaches the
/// model what not to trigger on.
struct BoundaryCorrectionExample: Equatable, Sendable {
    let reason: String
    let evidence: String
    let proposedTitle: String
    /// Nil when the user said "I'm still on the same thing".
    let correctedTitle: String?
    let accepted: Bool
}

/// The model's answer.
struct BoundaryVerdict: Equatable, Sendable {
    let sameTask: Bool
    /// Already clamped to the allowed window — never the raw model output.
    let boundaryAt: Date?
    let title: String?
    let role: String?
    let project: String?
    let customer: String?
    let todo: String?
    let confidence: Double
    let rationale: String
    let raw: String
}
