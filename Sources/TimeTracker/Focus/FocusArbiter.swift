import Foundation

/// Decides, continuously, whether the task being tracked is still the task being done.
///
/// This replaces the app's central assumption. Previously three sources raced to create
/// an entry and whichever won froze it: `ActivityWatchdog` returned early whenever a
/// timer was running, and `CalendarService` refused to switch for the same reason. The
/// AI was never consulted again for the entire life of an entry, which is why a meeting
/// could start while a previous task kept running.
///
/// The arbiter runs whether or not something is being tracked, gathers evidence, and
/// decides keep / stop / ask. It holds no `ModelContext`: every input and effect is an
/// injected closure, so the sequencing rules that actually matter — never two
/// consultations at once, never act on a stale proposal, never exceed the budget — are
/// ordinary unit tests instead of hopes.
@MainActor
final class FocusArbiter {

    // MARK: - Dependencies

    struct Dependencies {
        var now: () -> Date = { Date() }
        var samples: (Date, Date) -> [SignalSample] = { _, _ in [] }
        var idleSpans: (Date, Date) -> [IdleSpan] = { _, _ in [] }
        var meetings: (Date, Date) -> [MeetingWindow] = { _, _ in [] }
        var currentEntry: () -> EntryContext? = { nil }
        var isIdle: () -> Bool = { false }
        var idleStartedAt: () -> Date? = { nil }
        /// When the user last edited the running entry by hand.
        var lastManualEditAt: () -> Date? = { nil }
        var allowedCalendarIds: () -> Set<String>? = { nil }
        var suppressedTransitions: () -> Set<String> = { [] }

        /// Builds the model's input for a candidate.
        var buildContext: (ContextSegmenter.BoundaryCandidate) -> BoundaryContext?
        /// Calls the model.
        var consult: (BoundaryContext) async throws -> BoundaryVerdict
        /// Applies the chosen action, given the id of the decision it was logged
        /// under so the user's answer can be attached to the right row.
        var apply: (FocusPolicy.Action, ContextSegmenter.BoundaryCandidate, UUID) -> Void
        /// Ends the running entry at a supplied instant.
        var stop: (Date) -> Void
        /// Appends to the decision log.
        var record: (FocusDecision) -> Void
    }

    enum Phase: Equatable {
        case watching
        case consulting
        case awaitingUser(boundaryAt: Date, isHard: Bool)
    }

    private(set) var phase: Phase = .watching
    private(set) var budget = LLMBudget()
    /// Counters for the Debug pane: seen / asked / accepted.
    private(set) var candidatesSeen = 0
    private(set) var questionsAsked = 0

    private var deps: Dependencies
    private var settings: () -> FocusPolicy.Settings
    private var segmenterConfig: () -> ContextSegmenter.Config

    /// Per-bucket cooldowns, so a stubborn signal cannot ask twice in a row.
    private var lastAskPerBucket: [String: Date] = [:]
    private var recentPromptTimes: [Date] = []
    private var pollTimer: Timer?

    init(
        dependencies: Dependencies,
        settings: @escaping () -> FocusPolicy.Settings = { .default },
        segmenterConfig: @escaping () -> ContextSegmenter.Config = { .default },
        budget: LLMBudget = LLMBudget()
    ) {
        self.deps = dependencies
        self.settings = settings
        self.segmenterConfig = segmenterConfig
        self.budget = budget
    }

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        AppLogger.timer.info("FocusArbiter started")
        AppLogger.log("timer", level: .info, "arbiter_started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - The decision

    func tick() async {
        let now = deps.now()
        let config = settings()

        // 1. HARD STOP — prolonged idle ends the entry with no model call at all.
        if deps.isIdle(), deps.currentEntry() != nil, let idleStart = deps.idleStartedAt() {
            deps.stop(idleStart)
            phase = .watching
            return
        }
        // Nothing else is worth doing while the user is away.
        if deps.isIdle() { return }

        // 2. A question is outstanding. Only a hard boundary may supersede it, so an
        //    unanswered prompt cannot block a meeting from being noticed.
        if case let .awaitingUser(_, isHard) = phase, isHard { return }

        // 3. Never two consultations in flight.
        if phase == .consulting { return }

        // 4. Never overwrite a human. Editing an entry by hand buys protection.
        if let edited = deps.lastManualEditAt(),
           now.timeIntervalSince(edited) < TimeInterval(config.manualLockMinutes) * 60 {
            return
        }

        // 5. Segment.
        let lookback = segmenterConfig().lookbackSeconds
        var segConfig = segmenterConfig()
        segConfig.suppressedTransitions = deps.suppressedTransitions()
        let output = ContextSegmenter.evaluate(
            ContextSegmenter.Input(
                now: now,
                samples: deps.samples(now.addingTimeInterval(-lookback), now),
                idleSpans: deps.idleSpans(now.addingTimeInterval(-lookback), now),
                meetings: deps.meetings(now.addingTimeInterval(-lookback), now.addingTimeInterval(3600)),
                currentEntry: deps.currentEntry(),
                allowedCalendarIds: deps.allowedCalendarIds(),
                config: segConfig
            )
        )
        candidatesSeen += output.candidates.count

        // 6. Only settled candidates are actionable — that is the whole point of the
        //    dwell gate. A hard boundary (a corroborated meeting) may act at once.
        guard let candidate = output.candidates.first(where: { !$0.isProvisional || $0.isHard })
        else { return }

        // If a soft question is outstanding, replace it only with a hard candidate.
        if case .awaitingUser = phase, !candidate.isHard { return }

        let bucket = bucketKey(for: candidate)

        // 7. Cooldowns and the prompt rate limit, before any spend.
        if let last = lastAskPerBucket[bucket],
           now.timeIntervalSince(last) < cooldownSeconds(for: candidate) {
            record(.suppressed, candidate: candidate, bucket: bucket, note: "cooldown")
            return
        }
        recentPromptTimes.removeAll { now.timeIntervalSince($0) >= 3600 }
        if recentPromptTimes.count >= config.maxPromptsPerHour {
            record(.suppressed, candidate: candidate, bucket: bucket, note: "prompt_rate_limit")
            return
        }

        // 8. Budget. When it is spent we still surface the boundary, just without a
        //    proposed label — losing the boundary entirely would be worse.
        guard budget.consume(at: now, isHard: candidate.isHard) else {
            record(.suppressed, candidate: candidate, bucket: bucket, note: "budget_exhausted")
            askWithoutLabel(candidate: candidate, bucket: bucket, now: now)
            return
        }

        guard let context = deps.buildContext(candidate) else {
            record(.error, candidate: candidate, bucket: bucket, note: "no_context")
            return
        }

        // 9. Consult.
        phase = .consulting
        let verdict: BoundaryVerdict
        do {
            verdict = try await deps.consult(context)
        } catch {
            phase = .watching
            record(.error, candidate: candidate, bucket: bucket, note: error.localizedDescription)
            AppLogger.log("ai", level: .error, "boundary_consult_failed: \(error.localizedDescription)")
            return
        }

        // 10. Re-check: the world may have moved while we waited on the network.
        guard let entry = deps.currentEntry(), entry.id == context.currentEntry?.id else {
            phase = .watching
            record(.suppressed, candidate: candidate, bucket: bucket, note: "stale_proposal")
            return
        }

        let action = FocusPolicy.decide(
            verdict: verdict,
            candidateScore: candidate.score,
            currentEntryAge: deps.now().timeIntervalSince(entry.startAt),
            evidence: describe(candidate),
            settings: config
        )

        switch action {
        case .keep:
            phase = .watching
            // The model saw the same evidence and disagreed with the machine. Worth
            // logging: this is the signal that tunes the segmenter's thresholds.
            record(.noop, candidate: candidate, bucket: bucket,
                   confidence: verdict.confidence, rationale: verdict.rationale, raw: verdict.raw)

        case let .ask(proposal), let .correctInPlace(proposal):
            phase = .awaitingUser(boundaryAt: proposal.boundaryAt, isHard: candidate.isHard)
            lastAskPerBucket[bucket] = now
            recentPromptTimes.append(now)
            questionsAsked += 1
            let decisionID = record(
                .asked, candidate: candidate, bucket: bucket,
                confidence: verdict.confidence, rationale: verdict.rationale,
                raw: verdict.raw, proposal: proposal
            )
            deps.apply(action, candidate, decisionID)

        case let .switchTo(proposal):
            phase = .watching
            lastAskPerBucket[bucket] = now
            let decisionID = record(
                .autoSwitched, candidate: candidate, bucket: bucket,
                confidence: verdict.confidence, rationale: verdict.rationale,
                raw: verdict.raw, proposal: proposal
            )
            deps.apply(action, candidate, decisionID)
        }
    }

    /// Called by the UI once the user answers, so a new proposal can be considered.
    func userResponded() {
        phase = .watching
    }

    // MARK: - Degraded ask

    private func askWithoutLabel(
        candidate: ContextSegmenter.BoundaryCandidate,
        bucket: String,
        now: Date
    ) {
        let proposal = FocusPolicy.Proposal(
            boundaryAt: candidate.at,
            title: nil, role: nil, project: nil, customer: nil, todo: nil,
            confidence: candidate.score,
            rationale: "Local signals only — model budget exhausted.",
            evidence: describe(candidate)
        )
        phase = .awaitingUser(boundaryAt: candidate.at, isHard: candidate.isHard)
        lastAskPerBucket[bucket] = now
        recentPromptTimes.append(now)
        questionsAsked += 1
        let decisionID = record(.asked, candidate: candidate, bucket: bucket, proposal: proposal)
        deps.apply(.ask(proposal), candidate, decisionID)
    }

    // MARK: - Helpers

    /// Cooldowns differ by what raised the candidate: a meeting edge is a rare, precise
    /// event worth acting on quickly; ordinary activity drift is not.
    private func cooldownSeconds(for candidate: ContextSegmenter.BoundaryCandidate) -> TimeInterval {
        if candidate.reasons.contains(.meetingStart) || candidate.reasons.contains(.meetingEnd) {
            return 5 * 60
        }
        if candidate.reasons.contains(.idleGap) { return 10 * 60 }
        return 30 * 60
    }

    /// Bucket keys are what the learned weights are stored against, so they must be
    /// coarse enough to accumulate statistics and specific enough to be actionable.
    private func bucketKey(for candidate: ContextSegmenter.BoundaryCandidate) -> String {
        if candidate.reasons.contains(.meetingStart) {
            return candidate.isHard ? "meetingStart|corroborated" : "meetingStart|scheduled"
        }
        if candidate.reasons.contains(.meetingEnd) { return "meetingEnd" }
        if candidate.reasons.contains(.idleGap) { return "idleReturn" }
        return "activityDrift"
    }

    private func describe(_ candidate: ContextSegmenter.BoundaryCandidate) -> String {
        var parts: [String] = []
        if let before = candidate.before.topApp { parts.append("before: \(before)") }
        if let after = candidate.after.topApp { parts.append("after: \(after)") }
        parts.append("score \(String(format: "%.2f", candidate.score))")
        if !candidate.reasons.isEmpty {
            parts.append(candidate.reasons.map(\.rawValue).joined(separator: "+"))
        }
        return parts.joined(separator: " · ")
    }

    @discardableResult
    private func record(
        _ kind: FocusDecisionKind,
        candidate: ContextSegmenter.BoundaryCandidate,
        bucket: String,
        note: String? = nil,
        confidence: Double = 0,
        rationale: String? = nil,
        raw: String? = nil,
        proposal: FocusPolicy.Proposal? = nil
    ) -> UUID {
        let decision = FocusDecision(
            kind: kind,
            bucket: bucket,
            boundaryAt: proposal?.boundaryAt ?? candidate.at,
            score: candidate.score,
            confidence: confidence,
            reasons: candidate.reasons,
            evidence: describe(candidate),
            rationale: rationale ?? note,
            rawResponse: raw,
            previousTitle: deps.currentEntry()?.title ?? "",
            proposedTitle: proposal?.title ?? "",
            proposedRoleName: proposal?.role,
            proposedProjectName: proposal?.project,
            proposedCustomerName: proposal?.customer,
            proposedTodoTitle: proposal?.todo,
            fromEntryID: deps.currentEntry()?.id
        )
        deps.record(decision)
        return decision.id
    }
}
