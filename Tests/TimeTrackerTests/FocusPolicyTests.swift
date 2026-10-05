import XCTest
@testable import TimeTracker

final class FocusPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func verdict(
        sameTask: Bool = false,
        confidence: Double = 0.7,
        title: String? = "Globex migration"
    ) -> BoundaryVerdict {
        BoundaryVerdict(
            sameTask: sameTask,
            boundaryAt: sameTask ? nil : now.addingTimeInterval(-600),
            title: title, role: nil, project: nil, customer: nil, todo: nil,
            confidence: confidence, rationale: "r", raw: "{}"
        )
    }

    private func decide(
        _ v: BoundaryVerdict,
        age: TimeInterval = 3600,
        settings: FocusPolicy.Settings = .default
    ) -> FocusPolicy.Action {
        FocusPolicy.decide(
            verdict: v, candidateScore: 0.6, currentEntryAge: age,
            evidence: "e", settings: settings
        )
    }

    func test_modelSayingSameTaskAlwaysWins() {
        // The cheapest false-positive filter in the system.
        XCTAssertEqual(decide(verdict(sameTask: true, confidence: 0.99)), .keep)
    }

    func test_autoSwitchIsOffByDefault() {
        // The user asked to be consulted; nothing may mutate unattended.
        guard case .ask = decide(verdict(confidence: 1.0)) else {
            return XCTFail("must ask, never switch, with default settings")
        }
    }

    func test_autoSwitchPathWorksWhenEnabled() {
        var settings = FocusPolicy.Settings.default
        settings.autoSwitchThreshold = 0.8
        guard case .switchTo = decide(verdict(confidence: 0.9), settings: settings) else {
            return XCTFail("expected switchTo once enabled")
        }
    }

    func test_lowConfidenceAsksWithoutAssertingALabel() {
        guard case let .ask(proposal) = decide(verdict(confidence: 0.2)) else {
            return XCTFail("expected ask")
        }
        XCTAssertFalse(proposal.hasLabel, "must not assert a label we don't believe")
        XCTAssertNotNil(proposal.boundaryAt)
    }

    func test_moderateConfidenceAsksWithALabel() {
        guard case let .ask(proposal) = decide(verdict(confidence: 0.6)) else {
            return XCTFail("expected ask")
        }
        XCTAssertTrue(proposal.hasLabel)
        XCTAssertEqual(proposal.title, "Globex migration")
    }

    func test_youngEntryIsCorrectedRatherThanSplit() {
        guard case .correctInPlace = decide(verdict(confidence: 0.8), age: 60) else {
            return XCTFail("expected correctInPlace for a 60 s old entry")
        }
    }

    func test_youngEntryWithWeakConfidenceIsLeftAlone() {
        XCTAssertEqual(decide(verdict(confidence: 0.2), age: 60), .keep)
    }

    func test_missingBoundaryIsIgnored() {
        let broken = BoundaryVerdict(
            sameTask: false, boundaryAt: nil, title: "X",
            role: nil, project: nil, customer: nil, todo: nil,
            confidence: 0.9, rationale: "r", raw: "{}"
        )
        XCTAssertEqual(decide(broken), .keep)
    }
}

final class LLMBudgetTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func test_enforcesMinimumSpacing() {
        var budget = LLMBudget()
        XCTAssertTrue(budget.consume(at: now, isHard: false))
        XCTAssertFalse(budget.consume(at: now.addingTimeInterval(60), isHard: false))
        XCTAssertTrue(budget.consume(at: now.addingTimeInterval(200), isHard: false))
    }

    func test_enforcesHourlyCap() {
        var budget = LLMBudget(maxPerHour: 3, minimumSpacingSeconds: 0)
        for i in 0..<3 {
            XCTAssertTrue(budget.consume(at: now.addingTimeInterval(Double(i)), isHard: false))
        }
        XCTAssertFalse(budget.consume(at: now.addingTimeInterval(4), isHard: false))
        // An hour later the window has rolled.
        XCTAssertTrue(budget.consume(at: now.addingTimeInterval(3700), isHard: false))
    }

    func test_reserveKeepsRoomForHardBoundaries() {
        // A chatty afternoon of app switching must not starve a real meeting.
        var budget = LLMBudget(
            maxPerHour: 1000, maxPerDay: 10,
            minimumSpacingSeconds: 0, reservedForHardBoundaries: 3
        )
        for i in 0..<7 {
            XCTAssertTrue(budget.consume(at: now.addingTimeInterval(Double(i)), isHard: false))
        }
        XCTAssertFalse(budget.consume(at: now.addingTimeInterval(8), isHard: false),
                       "soft boundaries stop at the reserve")
        XCTAssertTrue(budget.consume(at: now.addingTimeInterval(9), isHard: true),
                      "hard boundaries may use the reserve")
    }

    func test_prunesEntriesOlderThanADay() {
        var budget = LLMBudget(minimumSpacingSeconds: 0)
        _ = budget.consume(at: now, isHard: false)
        budget.prune(now: now.addingTimeInterval(90_000))
        XCTAssertEqual(budget.remainingToday(at: now.addingTimeInterval(90_000)), budget.maxPerDay)
    }
}
