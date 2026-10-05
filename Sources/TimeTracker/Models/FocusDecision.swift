import Foundation
import SwiftData

/// Append-only record of every boundary the arbiter considered.
///
/// Three jobs at once: it is the debugging surface ("47 candidates seen, 12 asked, 9
/// accepted"), the data behind the review UI, and the learning corpus — both the
/// negative few-shots in the prompt and the deterministic per-signal weights. Logging
/// suppressed candidates as well as raised ones is deliberate; the ones that never
/// reached the user are exactly what tuning needs.
///
/// Every property carries its default on the declaration so SwiftData lightweight
/// migration can apply it.
@Model
final class FocusDecision {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()

    /// `FocusDecisionKind.rawValue`
    var kindRaw: String = ""
    /// Bucket key for learned weights, e.g. "meetingStart|zoom", "calendarStart|free".
    var bucket: String = ""

    var boundaryAt: Date? = nil
    /// Segmenter score, 0...1.
    var score: Double = 0
    /// Model confidence, 0...1.
    var confidence: Double = 0
    /// Comma-separated `BoundaryReason` raw values.
    var reasonsRaw: String = ""
    /// Human-readable evidence, shown in the prompt UI and the review list.
    var evidence: String = ""
    var rationale: String? = nil
    var providerLabel: String? = nil
    /// The model's raw text. `EntryDraft.raw` was computed and thrown away before.
    var rawResponse: String? = nil

    var previousTitle: String = ""
    var proposedTitle: String = ""
    var proposedRoleName: String? = nil
    var proposedProjectName: String? = nil
    var proposedCustomerName: String? = nil
    var proposedTodoTitle: String? = nil

    var fromEntryID: UUID? = nil
    var toEntryID: UUID? = nil
    /// `"beforeBundleId>afterBundleId"`, the key learned suppression is stored against.
    var transition: String? = nil

    /// `FocusUserResponse.rawValue`, nil while unanswered.
    var userResponseRaw: String? = nil
    var respondedAt: Date? = nil
    var correctedTitle: String? = nil
    var correctedBoundaryAt: Date? = nil

    init(
        kind: FocusDecisionKind,
        bucket: String = "",
        boundaryAt: Date? = nil,
        score: Double = 0,
        confidence: Double = 0,
        reasons: [BoundaryReason] = [],
        evidence: String = "",
        rationale: String? = nil,
        providerLabel: String? = nil,
        rawResponse: String? = nil,
        previousTitle: String = "",
        proposedTitle: String = "",
        proposedRoleName: String? = nil,
        proposedProjectName: String? = nil,
        proposedCustomerName: String? = nil,
        proposedTodoTitle: String? = nil,
        fromEntryID: UUID? = nil,
        transition: String? = nil
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.kindRaw = kind.rawValue
        self.bucket = bucket
        self.boundaryAt = boundaryAt
        self.score = score
        self.confidence = confidence
        self.reasonsRaw = reasons.map(\.rawValue).joined(separator: ",")
        self.evidence = evidence
        self.rationale = rationale
        self.providerLabel = providerLabel
        self.rawResponse = rawResponse
        self.previousTitle = previousTitle
        self.proposedTitle = proposedTitle
        self.proposedRoleName = proposedRoleName
        self.proposedProjectName = proposedProjectName
        self.proposedCustomerName = proposedCustomerName
        self.proposedTodoTitle = proposedTodoTitle
        self.fromEntryID = fromEntryID
        self.transition = transition
    }

    var kind: FocusDecisionKind {
        get { FocusDecisionKind(rawValue: kindRaw) ?? .noop }
        set { kindRaw = newValue.rawValue }
    }

    var userResponse: FocusUserResponse? {
        get { userResponseRaw.flatMap(FocusUserResponse.init(rawValue:)) }
        set { userResponseRaw = newValue?.rawValue }
    }

    var reasons: [BoundaryReason] {
        reasonsRaw.split(separator: ",").compactMap { BoundaryReason(rawValue: String($0)) }
    }
}

enum FocusDecisionKind: String, Codable, CaseIterable, Sendable {
    /// Seen by the segmenter but never shown — cooldown, budget, or too weak.
    case suppressed
    /// The model was consulted and said the task had not changed.
    case noop
    /// A question was put to the user.
    case asked
    /// Applied without asking (only possible once auto-switch is enabled).
    case autoSwitched
    /// Entry ended without a replacement.
    case stopped
    case error
}

enum FocusUserResponse: String, Codable, CaseIterable, Sendable {
    /// "I'm still on the same thing" — the boundary was wrong.
    case keptCurrent
    /// "Yes, switch to that" — boundary and label both right.
    case switched
    /// "It's something else" — boundary right, label wrong. The most informative answer.
    case switchedEdited
    /// Dismissed without answering.
    case dismissed
    /// Expired unanswered.
    case timedOut
    /// Applied, then undone.
    case undone
    /// Replaced by a newer question, or made moot because the entry it was about
    /// stopped or changed before the user answered.
    case superseded
}
