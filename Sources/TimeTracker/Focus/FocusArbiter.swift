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
/// decides keep / ask. It holds no `ModelContext`: every input and effect is an
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
        /// Appends to the decision log.
        var record: (FocusDecision) -> Void
        /// Saves the budget after each call, so the daily ceiling survives a relaunch.
        var persistBudget: (LLMBudget) -> Void = { _ in }
        /// A calendar meeting the user has visibly joined (microphone on while a
        /// trustworthy event is in progress), with when the call began. Nil when not in
        /// one, or when the user turned automatic meeting switches off.
        var joinedMeeting: () -> (meeting: MeetingWindow, since: Date)? = { nil }
        /// Role / project / customer names learned from past entries with this title.
        var labelsForMeeting: (MeetingWindow) -> (role: String?, project: String?, customer: String?) = { _ in (nil, nil, nil) }
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
    /// Candidates already dealt with — asked, or judged "same task" by the model.
    /// The segmenter keeps re-emitting a boundary for as long as it is inside the
    /// lookback window, so without this the same instant was asked about again.
    private var handledCandidates: [String: Date] = [:]
    /// Suppressions already logged, so a stuck candidate writes one row, not one per tick.
    private var loggedSuppressions: Set<String> = []
    /// Meetings already switched to (or found already tracked), so an undo sticks.
    private var handledMeetingJoins: Set<String> = []
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

        // 0. Nothing is worth doing while the user is away. Idle never changes an entry
        //    here; `EntryCompletionService` removes the away time on return.
        if deps.isIdle() { return }

        // 1. Joining a calendar meeting is the one switch made without asking. The
        //    evidence is unambiguous — a real meeting is on the calendar and the
        //    microphone is on — and the user asked for it. It stays undoable.
        if phase != .consulting, let entry = deps.currentEntry(),
           switchToJoinedMeetingIfNeeded(entry: entry, now: now) {
            return
        }

        // 2. A question is outstanding. Only a hard boundary may supersede it, so an
        //    unanswered prompt cannot block a meeting from being noticed.
        if case let .awaitingUser(_, isHard) = phase, isHard { return }

        // 3. Never two consultations in flight.
        if phase == .consulting { return }

        // 3b. Nothing is being tracked, so there is no task to switch away from.
        //     Starting from cold is the calendar's and the watchdog's job; consulting
        //     here only spent budget on answers that were then discarded as stale.
        guard let entry = deps.currentEntry() else { return }
        pruneHandled(now: now)

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
                currentEntry: entry,
                allowedCalendarIds: deps.allowedCalendarIds(),
                config: segConfig
            )
        )
        candidatesSeen += output.candidates.count

        // 6. Only settled candidates are actionable — that is the whole point of the
        //    dwell gate. A hard boundary (a corroborated meeting) may act at once.
        //    Walk the list rather than taking the top one: a strong candidate that is
        //    cooling down must not hide a weaker but newer one, such as a meeting.
        let awaiting: Bool = { if case .awaitingUser = phase { return true } else { return false } }()
        var chosen: ContextSegmenter.BoundaryCandidate?
        for candidate in output.candidates where !candidate.isProvisional || candidate.isHard {
            // If a soft question is outstanding, replace it only with a hard candidate.
            if awaiting && !candidate.isHard { continue }
            if handledCandidates[handledKey(candidate, entryID: entry.id)] != nil { continue }
            let bucket = bucketKey(for: candidate)
            // 7. Cooldowns, before any spend.
            if let last = lastAskPerBucket[bucket],
               now.timeIntervalSince(last) < cooldownSeconds(for: candidate) {
                recordSuppressionOnce(candidate, bucket: bucket, entryID: entry.id, note: "cooldown")
                continue
            }
            chosen = candidate
            break
        }
        guard let candidate = chosen else { return }
        let bucket = bucketKey(for: candidate)
        let key = handledKey(candidate, entryID: entry.id)

        recentPromptTimes.removeAll { now.timeIntervalSince($0) >= 3600 }
        if recentPromptTimes.count >= config.maxPromptsPerHour {
            recordSuppressionOnce(candidate, bucket: bucket, entryID: entry.id, note: "prompt_rate_limit")
            return
        }

        // 8. Budget. Too soon after the last call is transient: try again next tick.
        //    When the allowance is really spent we still surface the boundary, just
        //    without a proposed label — losing the boundary entirely would be worse.
        switch budget.denial(at: now, isHard: candidate.isHard) {
        case .spacing?:
            return
        case .exhausted?:
            recordSuppressionOnce(candidate, bucket: bucket, entryID: entry.id, note: "budget_exhausted")
            handledCandidates[key] = now
            askWithoutLabel(candidate: candidate, bucket: bucket, now: now)
            return
        case nil:
            break
        }

        guard let context = deps.buildContext(candidate) else {
            record(.error, candidate: candidate, bucket: bucket, note: "no_context")
            return
        }
        // Spend only once a call will really be made.
        _ = budget.consume(at: now, isHard: candidate.isHard)
        deps.persistBudget(budget)

        // 9. Consult.
        phase = .consulting
        let verdict: BoundaryVerdict
        do {
            verdict = try await deps.consult(context)
        } catch {
            phase = .watching
            // Back off this bucket so a failing provider is not retried every tick.
            lastAskPerBucket[bucket] = now
            record(.error, candidate: candidate, bucket: bucket, note: error.localizedDescription)
            AppLogger.log("ai", level: .error, "boundary_consult_failed: \(error.localizedDescription)")
            return
        }

        // 10. Re-check: the world may have moved while we waited on the network.
        guard let latest = deps.currentEntry(), latest.id == context.currentEntry?.id else {
            handledCandidates[key] = now
            phase = .watching
            record(.suppressed, candidate: candidate, bucket: bucket, note: "stale_proposal")
            return
        }

        let action = FocusPolicy.decide(
            verdict: verdict,
            candidateScore: candidate.score,
            currentEntryAge: deps.now().timeIntervalSince(latest.startAt),
            evidence: describe(candidate),
            settings: config
        )

        switch action {
        case .keep:
            phase = .watching
            // The model has ruled on this boundary. Do not ask it again, and let the
            // bucket cool down as if the user had been asked.
            handledCandidates[key] = now
            lastAskPerBucket[bucket] = now
            // The model saw the same evidence and disagreed with the machine. Worth
            // logging: this is the signal that tunes the segmenter's thresholds.
            record(.noop, candidate: candidate, bucket: bucket,
                   confidence: verdict.confidence, rationale: verdict.rationale, raw: verdict.raw)

        case let .ask(proposal), let .correctInPlace(proposal):
            phase = .awaitingUser(boundaryAt: proposal.boundaryAt, isHard: candidate.isHard)
            handledCandidates[key] = now
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
            handledCandidates[key] = now
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
    ///
    /// Only releases a wait on the user. If a consultation is in flight (a hard
    /// boundary superseding a soft question), dropping to `.watching` would let the
    /// next tick start a second one alongside it.
    func userResponded() {
        if case .awaitingUser = phase { phase = .watching }
    }

    /// Counts a model call made outside the arbiter against the same budget.
    func noteExternalModelCall(at now: Date = Date()) {
        budget.record(at: now)
        deps.persistBudget(budget)
    }

    // MARK: - Meeting join

    private func switchToJoinedMeetingIfNeeded(entry: EntryContext, now: Date) -> Bool {
        guard let (meeting, since) = deps.joinedMeeting() else { return false }
        guard !handledMeetingJoins.contains(meeting.eventId) else { return false }
        handledMeetingJoins.insert(meeting.eventId)

        // Already tracking it: started from this meeting, or the user named it.
        if entry.title.caseInsensitiveCompare(meeting.title) == .orderedSame { return false }
        // The user started something by hand after the meeting began: that was a
        // deliberate choice, and overriding it is exactly what they would not want.
        if let lastEdit = deps.lastManualEditAt(), lastEdit >= meeting.start { return false }

        // The meeting began when the call did, but never before the event's start
        // nor more than 30 minutes back.
        let boundary = min(now, max(meeting.start, since, now.addingTimeInterval(-1800)))
        let labels = deps.labelsForMeeting(meeting)
        let proposal = FocusPolicy.Proposal(
            boundaryAt: boundary,
            title: meeting.title,
            role: labels.role, project: labels.project, customer: labels.customer,
            todo: nil,
            confidence: 1,
            rationale: "Joined a calendar meeting.",
            evidence: "Microphone on during \"\(meeting.title)\""
        )
        let decision = FocusDecision(
            kind: .autoSwitched,
            bucket: "meetingJoin",
            boundaryAt: boundary,
            score: 1,
            confidence: 1,
            reasons: [.meetingStart],
            evidence: proposal.evidence,
            rationale: proposal.rationale,
            previousTitle: entry.title,
            proposedTitle: meeting.title,
            proposedRoleName: labels.role,
            proposedProjectName: labels.project,
            proposedCustomerName: labels.customer,
            fromEntryID: entry.id
        )
        deps.record(decision)
        phase = .watching
        AppLogger.log("timer", level: .info, "meeting_join_switch event=\(meeting.eventId)")
        deps.apply(.switchTo(proposal), Self.meetingCandidate(meeting, at: boundary), decision.id)
        return true
    }

    /// `apply` takes a candidate for logging; a meeting join has no segmenter one.
    private static func meetingCandidate(_ meeting: MeetingWindow, at: Date) -> ContextSegmenter.BoundaryCandidate {
        ContextSegmenter.BoundaryCandidate(
            at: at, score: 1, reasons: [.meetingStart],
            before: .empty, after: .empty,
            isProvisional: false, isHard: true, meetingEventId: meeting.eventId
        )
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

    /// Identifies a boundary across ticks: the segmenter re-emits the same instant
    /// (a sample timestamp or a meeting edge) for as long as it is in the lookback.
    private func handledKey(_ candidate: ContextSegmenter.BoundaryCandidate, entryID: UUID) -> String {
        let minute = Int(candidate.at.timeIntervalSince1970 / 60)
        return "\(entryID.uuidString)|\(minute)|\(candidate.meetingEventId ?? "")"
    }

    private func pruneHandled(now: Date) {
        // Twice the lookback: by then the segmenter can no longer emit the instant.
        let horizon = segmenterConfig().lookbackSeconds * 2
        handledCandidates = handledCandidates.filter { now.timeIntervalSince($0.value) < horizon }
        if loggedSuppressions.count > 500 { loggedSuppressions.removeAll() }
    }

    private func recordSuppressionOnce(
        _ candidate: ContextSegmenter.BoundaryCandidate,
        bucket: String,
        entryID: UUID,
        note: String
    ) {
        let key = handledKey(candidate, entryID: entryID) + "|" + note
        guard loggedSuppressions.insert(key).inserted else { return }
        record(.suppressed, candidate: candidate, bucket: bucket, note: note)
    }

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
            fromEntryID: deps.currentEntry()?.id,
            transition: candidate.topTransition
        )
        deps.record(decision)
        return decision.id
    }
}
