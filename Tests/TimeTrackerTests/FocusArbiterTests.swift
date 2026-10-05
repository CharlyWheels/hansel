import XCTest
@testable import TimeTracker

/// The arbiter's value is its sequencing: what it refuses to do, and when. These are
/// the failures that would otherwise only appear in production, hours apart.
@MainActor
final class FocusArbiterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var clock: Date = Date(timeIntervalSince1970: 1_700_000_000)

    // Recorders
    private var applied: [FocusPolicy.Action] = []
    private var decisions: [FocusDecision] = []
    private var consultCount = 0

    override func setUp() {
        super.setUp()
        clock = t0.addingTimeInterval(3000)
        applied = []; decisions = []; consultCount = 0
    }

    // MARK: - Fixtures

    /// A sustained switch that always sits 20 minutes behind `clock`, so the boundary
    /// stays inside the lookback window however far the test advances time.
    private func switchingSamples() -> [SignalSample] {
        let boundary = clock.addingTimeInterval(-1200)
        return absoluteStream(from: clock.addingTimeInterval(-3000), to: boundary,
                              "com.google.Chrome", "acme api ticket",
                              "https://acme.atlassian.net/browse/A-1")
            + absoluteStream(from: boundary, to: clock,
                             "com.microsoft.VSCode", "globex invoicing migration",
                             "https://globex.github.io/docs")
    }

    private func absoluteStream(
        from: Date, to: Date,
        _ bundle: String, _ title: String, _ url: String? = nil,
        flags: SignalFlags = []
    ) -> [SignalSample] {
        var out: [SignalSample] = []
        var t = from
        while t < to {
            out.append(SignalSample(timestamp: t, bundleId: bundle, appName: bundle,
                                    windowTitle: title, url: url, flags: flags))
            t = t.addingTimeInterval(30)
        }
        return out
    }

    private func stream(
        _ from: TimeInterval, _ to: TimeInterval,
        _ bundle: String, _ title: String, _ url: String? = nil,
        flags: SignalFlags = []
    ) -> [SignalSample] {
        stride(from: from, to: to, by: 30).map {
            SignalSample(timestamp: t0.addingTimeInterval($0), bundleId: bundle,
                         appName: bundle, windowTitle: title, url: url, flags: flags)
        }
    }

    private func entry(startedAt offset: TimeInterval = 0) -> EntryContext {
        EntryContext(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                     title: "Acme API", startAt: t0.addingTimeInterval(offset))
    }

    /// Runs during the consult, to simulate the world moving while the network call
    /// is in flight.
    private var onConsult: (() -> Void)?

    private func makeArbiter(
        samples: [SignalSample]? = nil,
        idleSpans: [IdleSpan] = [],
        meetings: [MeetingWindow] = [],
        currentEntry: EntryContext? = nil,
        isIdle: Bool = false,
        idleStartedAt: Date? = nil,
        lastManualEditAt: Date? = nil,
        verdict: BoundaryVerdict? = nil,
        consultError: Error? = nil,
        entryProvider: (() -> EntryContext?)? = nil,
        hasEntry: Bool = true,
        settings: FocusPolicy.Settings = .default,
        budget: LLMBudget = LLMBudget()
    ) -> FocusArbiter {
        let resolvedEntry = currentEntry ?? entry(startedAt: -6000)
        var deps = FocusArbiter.Dependencies(
            buildContext: { [weak self] candidate in
                guard let self else { return nil }
                return BoundaryContext(
                    currentEntry: entryProvider?() ?? resolvedEntry,
                    boundaryAt: candidate.at, segmenterScore: candidate.score,
                    reasons: candidate.reasons, before: [], after: [], idleSpans: [],
                    meeting: nil, meetingCorroborated: false,
                    projects: [], customers: [], roles: [], activeTodos: [], recentEntries: [],
                    ruleHints: RuleEngine.Hints(), corrections: [],
                    now: self.clock,
                    earliestAllowed: candidate.at.addingTimeInterval(-600),
                    latestAllowed: self.clock
                )
            },
            consult: { [weak self] _ in
                self?.consultCount += 1
                self?.onConsult?()
                if let consultError { throw consultError }
                return verdict ?? BoundaryVerdict(
                    sameTask: false, boundaryAt: self?.clock.addingTimeInterval(-600),
                    title: "Globex migration", role: nil, project: nil, customer: nil,
                    todo: nil, confidence: 0.7, rationale: "different repo", raw: "{}"
                )
            },
            apply: { [weak self] action, _, _ in self?.applied.append(action) },
            record: { [weak self] decision in self?.decisions.append(decision) }
        )
        deps.now = { [weak self] in self?.clock ?? Date() }
        deps.samples = { [weak self] from, to in
            (samples ?? self?.switchingSamples() ?? []).filter { $0.timestamp >= from && $0.timestamp <= to }
        }
        deps.idleSpans = { _, _ in idleSpans }
        deps.meetings = { _, _ in meetings }
        deps.currentEntry = { hasEntry ? (entryProvider?() ?? resolvedEntry) : nil }
        deps.isIdle = { isIdle }
        deps.idleStartedAt = { idleStartedAt }
        deps.lastManualEditAt = { lastManualEditAt }
        return FocusArbiter(dependencies: deps, settings: { settings }, budget: budget)
    }

    // MARK: - Tests

    func test_sustainedSwitchAsksTheUserAndMutatesNothing() async {
        let arbiter = makeArbiter()
        await arbiter.tick()

        XCTAssertEqual(applied.count, 1)
        guard case .ask = applied.first else { return XCTFail("expected ask, got \(applied)") }
    }

    func test_modelSayingSameTaskProducesNoQuestion() async {
        let arbiter = makeArbiter(verdict: BoundaryVerdict(
            sameTask: true, boundaryAt: nil, title: nil, role: nil, project: nil,
            customer: nil, todo: nil, confidence: 0.9, rationale: "just checking chat", raw: "{}"
        ))
        await arbiter.tick()

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(decisions.last?.kind, .noop)
    }

    func test_neverConsultsTwiceForTheSameOutstandingQuestion() async {
        let arbiter = makeArbiter()
        await arbiter.tick()
        let afterFirst = consultCount
        await arbiter.tick()
        await arbiter.tick()

        XCTAssertEqual(consultCount, afterFirst, "an outstanding question must not re-consult")
        XCTAssertEqual(applied.count, 1)
    }

    func test_answeringReleasesTheArbiter() async {
        let arbiter = makeArbiter()
        await arbiter.tick()
        arbiter.userResponded()
        clock = clock.addingTimeInterval(4000)   // past cooldown and spacing
        await arbiter.tick()

        XCTAssertEqual(consultCount, 2)
    }

    func test_idleNeverStopsTheEntryOrConsults() async {
        // The user always stops the timer. Being away is asked about on return.
        let idleStart = clock.addingTimeInterval(-600)
        let arbiter = makeArbiter(isIdle: true, idleStartedAt: idleStart)
        await arbiter.tick()

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(consultCount, 0)
        XCTAssertTrue(decisions.isEmpty)
    }

    func test_recentManualEditProtectsTheEntry() async {
        // Never overwrite a human's own decision.
        let arbiter = makeArbiter(lastManualEditAt: clock.addingTimeInterval(-60))
        await arbiter.tick()

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(consultCount, 0)
    }

    func test_expiredManualLockNoLongerProtects() async {
        let arbiter = makeArbiter(lastManualEditAt: clock.addingTimeInterval(-3600))
        await arbiter.tick()
        XCTAssertEqual(applied.count, 1)
    }

    func test_cooldownSuppressesARepeatedSignal() async {
        let arbiter = makeArbiter()
        await arbiter.tick()
        arbiter.userResponded()
        clock = clock.addingTimeInterval(300)   // inside the 30 min drift cooldown
        await arbiter.tick()

        XCTAssertEqual(applied.count, 1, "same bucket must not ask again so soon")
        XCTAssertTrue(decisions.contains { $0.kind == .suppressed })
    }

    func test_staleProposalIsDiscardedWhenTheEntryChangedMidFlight() async {
        // The user stopped the timer while the network call was in flight.
        final class Box { var value: EntryContext? }
        let box = Box()
        box.value = entry(startedAt: -6000)

        let arbiter = makeArbiter(entryProvider: { box.value })
        onConsult = {
            box.value = EntryContext(id: UUID(), title: "Something else", startAt: self.t0)
        }
        await arbiter.tick()

        XCTAssertEqual(consultCount, 1)
        XCTAssertTrue(applied.isEmpty, "must not apply a proposal about a vanished entry")
        XCTAssertTrue(decisions.contains { $0.rationale == "stale_proposal" })
    }

    func test_consultFailureIsLoggedAndDoesNotWedgeTheArbiter() async {
        struct Boom: Error {}
        let arbiter = makeArbiter(consultError: Boom())
        await arbiter.tick()

        XCTAssertEqual(decisions.last?.kind, .error)
        XCTAssertEqual(arbiter.phase, .watching, "a failure must return to watching")
    }

    func test_budgetExhaustionStillSurfacesTheBoundaryWithoutALabel() async {
        var spent = LLMBudget(minimumSpacingSeconds: 0)
        for _ in 0..<LLMBudget().maxPerDay { _ = spent.consume(at: clock, isHard: true) }
        let arbiter = makeArbiter(budget: spent)
        await arbiter.tick()

        guard case let .ask(proposal) = applied.first else {
            return XCTFail("expected a degraded ask, got \(applied)")
        }
        XCTAssertFalse(proposal.hasLabel, "no budget means no label, but still a boundary")
        XCTAssertEqual(consultCount, 0)
    }

    func test_provisionalCandidateIsNotActedOn() async {
        // The switch happened 30 s ago — inside the dwell window.
        let samples = absoluteStream(
            from: clock.addingTimeInterval(-1830), to: clock.addingTimeInterval(-30),
            "com.google.Chrome", "acme api ticket", "https://acme.atlassian.net/browse/A-1"
        ) + absoluteStream(
            from: clock.addingTimeInterval(-30), to: clock,
            "com.microsoft.VSCode", "globex invoicing", "https://globex.github.io/docs"
        )
        let arbiter = makeArbiter(samples: samples)
        await arbiter.tick()

        XCTAssertTrue(applied.isEmpty, "must wait for the new context to settle")
        XCTAssertEqual(consultCount, 0)
    }

    func test_countersTrackWhatHappenedForTheDebugPane() async {
        let arbiter = makeArbiter()
        await arbiter.tick()
        XCTAssertGreaterThan(arbiter.candidatesSeen, 0)
        XCTAssertEqual(arbiter.questionsAsked, 1)
    }

    // MARK: - Re-asking and budget

    /// A switch at a fixed instant, so advancing the clock does not move the boundary.
    private func fixedSwitch(at boundary: Date) -> [SignalSample] {
        absoluteStream(from: boundary.addingTimeInterval(-1800), to: boundary,
                       "com.google.Chrome", "acme api ticket",
                       "https://acme.atlassian.net/browse/A-1")
            + absoluteStream(from: boundary, to: boundary.addingTimeInterval(7200),
                             "com.microsoft.VSCode", "globex invoicing migration",
                             "https://globex.github.io/docs")
    }

    func test_boundaryTheModelRejectedIsNotAskedOnTheNextTick() async {
        let arbiter = makeArbiter(
            samples: fixedSwitch(at: clock.addingTimeInterval(-1200)),
            verdict: BoundaryVerdict(
                sameTask: true, boundaryAt: nil, title: nil, role: nil, project: nil,
                customer: nil, todo: nil, confidence: 0.9, rationale: "same", raw: "{}"
            )
        )
        await arbiter.tick()
        XCTAssertEqual(consultCount, 1)
        clock = clock.addingTimeInterval(30)
        await arbiter.tick()
        clock = clock.addingTimeInterval(300)
        await arbiter.tick()

        XCTAssertEqual(consultCount, 1, "the model already ruled on this boundary")
        XCTAssertTrue(applied.isEmpty, "a rejected boundary must not turn into a label-free question")
    }

    func test_answeredBoundaryIsNotAskedAgainAfterTheCooldown() async {
        let arbiter = makeArbiter(samples: fixedSwitch(at: clock.addingTimeInterval(-600)))
        await arbiter.tick()
        XCTAssertEqual(applied.count, 1)
        arbiter.userResponded()
        clock = clock.addingTimeInterval(31 * 60)   // past the 30 min drift cooldown
        await arbiter.tick()

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(consultCount, 1)
    }

    func test_callSpacingWaitsInsteadOfAskingWithoutALabel() async {
        var recent = LLMBudget()
        recent.record(at: clock.addingTimeInterval(-60))
        let arbiter = makeArbiter(budget: recent)
        await arbiter.tick()

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(consultCount, 0)
        clock = clock.addingTimeInterval(200)
        await arbiter.tick()
        XCTAssertEqual(consultCount, 1, "once spacing allows, the boundary is consulted normally")
    }

    func test_nothingRunningMeansNoConsultation() async {
        let arbiter = makeArbiter(hasEntry: false)
        await arbiter.tick()
        XCTAssertEqual(consultCount, 0)
        XCTAssertTrue(applied.isEmpty)
    }

    func test_stuckSuppressionIsLoggedOnce() async {
        let arbiter = makeArbiter()
        await arbiter.tick()
        arbiter.userResponded()
        for _ in 0..<5 {
            clock = clock.addingTimeInterval(30)
            await arbiter.tick()
        }
        let suppressed = decisions.filter { $0.kind == .suppressed }
        XCTAssertLessThanOrEqual(suppressed.count, 2)
    }

    func test_budgetSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "LLMBudgetTests-\(UUID().uuidString)")!
        var budget = LLMBudget()
        budget.record(at: clock)
        budget.persist(defaults: defaults)
        let loaded = LLMBudget.loadPersisted(defaults: defaults, now: clock)
        XCTAssertEqual(loaded.timestamps, [clock])
        XCTAssertEqual(loaded.denial(at: clock.addingTimeInterval(10), isHard: false), .spacing)
    }
}
