import Foundation

/// Turns a segmenter candidate plus a model verdict into an action.
///
/// Pure, so the "when do we bother the user" rules — the single most important thing to
/// get right in this feature — are unit-testable rather than buried in a service.
enum FocusPolicy {

    struct Settings: Equatable, Sendable {
        /// Confidence at or above which a switch is applied without asking.
        ///
        /// Default is deliberately above 1.0: the switch path is fully implemented but
        /// OFF, because the user asked to be consulted before anything is mutated.
        /// Building it now rather than retrofitting it costs nothing and forces the
        /// decision log to carry confidence from the first day, so the threshold can be
        /// lowered later on evidence rather than on faith.
        var autoSwitchThreshold: Double = 1.01
        /// Below this the boundary is offered without a proposed label.
        var lowConfidenceThreshold: Double = 0.35
        /// A human's own edit is protected from being overwritten for this long.
        var manualLockMinutes: Int = 20
        /// Entries younger than this are corrected rather than split.
        var minSegmentMinutes: Int = 3
        /// Cap on questions per hour, independent of the LLM budget.
        var maxPromptsPerHour: Int = 4

        static let `default` = Settings()
    }

    struct Proposal: Equatable {
        let boundaryAt: Date
        let title: String?
        let role: String?
        let project: String?
        let customer: String?
        let todo: String?
        let confidence: Double
        let rationale: String
        let evidence: String
        /// Nil when the budget was spent and no label could be drafted.
        var hasLabel: Bool { title?.isEmpty == false }
    }

    enum Action: Equatable {
        case keep
        /// Put the question to the user; nothing is mutated yet.
        case ask(Proposal)
        /// Apply immediately (only reachable when auto-switch is enabled).
        case switchTo(Proposal)
        /// Rewrite the running entry rather than splitting a too-young one.
        case correctInPlace(Proposal)
    }

    static func decide(
        verdict: BoundaryVerdict,
        candidateScore: Double,
        currentEntryAge: TimeInterval,
        evidence: String,
        settings: Settings = .default
    ) -> Action {
        // The model saw the same evidence and says nothing changed. Cheapest and most
        // effective false-positive filter available.
        guard !verdict.sameTask else { return .keep }

        let boundaryAt = verdict.boundaryAt
        guard let boundaryAt else { return .keep }

        let proposal = Proposal(
            boundaryAt: boundaryAt,
            title: verdict.title,
            role: verdict.role,
            project: verdict.project,
            customer: verdict.customer,
            todo: verdict.todo,
            confidence: verdict.confidence,
            rationale: verdict.rationale,
            evidence: evidence
        )

        // Too young to split: we got the label wrong moments ago, so fix it rather than
        // leaving two fragments behind.
        if currentEntryAge < TimeInterval(settings.minSegmentMinutes) * 60 {
            return verdict.confidence >= 0.5 ? .correctInPlace(proposal) : .keep
        }

        if verdict.confidence >= settings.autoSwitchThreshold {
            return .switchTo(proposal)
        }

        // Low confidence still earns a question, but without asserting a label we do
        // not believe — "did you switch at 10:42?" is honest, a bad guess is not.
        if verdict.confidence < settings.lowConfidenceThreshold {
            return .ask(Proposal(
                boundaryAt: boundaryAt,
                title: nil,
                role: nil, project: nil, customer: nil, todo: nil,
                confidence: verdict.confidence,
                rationale: verdict.rationale,
                evidence: evidence
            ))
        }

        return .ask(proposal)
    }
}
