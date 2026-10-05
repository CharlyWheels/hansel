import XCTest
@testable import TimeTracker

/// These are the data-integrity invariants for retroactive splitting. Every failure
/// here would corrupt a day of tracked time.
final class TimelineGuardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let id = UUID()

    private func segment(startedSecondsAgo: TimeInterval) -> TimelineGuard.Segment {
        TimelineGuard.Segment(id: id, start: now.addingTimeInterval(-startedSecondsAgo))
    }

    func test_normalSplit_entriesMeetExactlyWithNoGap() {
        let plan = TimelineGuard.plan(
            current: segment(startedSecondsAgo: 3600),
            boundaryAt: now.addingTimeInterval(-600),
            now: now
        )
        guard case let .openNew(closeAt, startAt) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(closeAt, startAt, "adjacency must be exact — no gap, no overlap")
        XCTAssertEqual(closeAt, now.addingTimeInterval(-600))
    }

    func test_boundaryInTheFutureIsClampedToNow() {
        let plan = TimelineGuard.plan(
            current: segment(startedSecondsAgo: 3600),
            boundaryAt: now.addingTimeInterval(600),
            now: now
        )
        guard case let .openNew(closeAt, _) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(closeAt, now)
    }

    func test_boundaryBeforeEntryStart_neverProducesNegativeDuration() {
        let plan = TimelineGuard.plan(
            current: segment(startedSecondsAgo: 600),
            boundaryAt: now.addingTimeInterval(-5000),   // long before the entry began
            now: now
        )
        guard case let .openNew(closeAt, _) = plan else { return XCTFail("\(plan)") }
        let start = now.addingTimeInterval(-600)
        XCTAssertGreaterThan(closeAt, start)
        XCTAssertGreaterThanOrEqual(closeAt.timeIntervalSince(start), 180)
    }

    func test_boundaryJustAfterStart_isPushedPastMinimumSegment() {
        let plan = TimelineGuard.plan(
            current: segment(startedSecondsAgo: 600),
            boundaryAt: now.addingTimeInterval(-590),    // 10 s in: would be a sliver
            now: now
        )
        guard case let .openNew(closeAt, _) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(closeAt, now.addingTimeInterval(-600 + 180))
    }

    func test_youngEntryIsCorrectedInPlaceRatherThanSplit() {
        // We auto-started 40 s ago and got it wrong: rewrite, don't fragment.
        let plan = TimelineGuard.plan(
            current: segment(startedSecondsAgo: 40),
            boundaryAt: now.addingTimeInterval(-20),
            now: now
        )
        XCTAssertEqual(plan, .correctInPlace)
    }

    func test_noRunningEntryStartsFresh() {
        let plan = TimelineGuard.plan(
            current: nil,
            boundaryAt: now.addingTimeInterval(-600),
            now: now
        )
        XCTAssertEqual(plan, .startFresh(at: now.addingTimeInterval(-600)))
    }

    func test_freshStartBackdateIsCapped() {
        let plan = TimelineGuard.plan(
            current: nil,
            boundaryAt: now.addingTimeInterval(-99_999),
            now: now
        )
        XCTAssertEqual(plan, .startFresh(at: now.addingTimeInterval(-3600)))
    }

    func test_alreadyClosedSegmentIsRejected() {
        let closed = TimelineGuard.Segment(
            id: id, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-60)
        )
        guard case .reject = TimelineGuard.plan(current: closed, boundaryAt: now, now: now) else {
            return XCTFail("expected reject")
        }
    }

    func test_noPlanEverProducesAnOutOfOrderOrFutureBoundary() {
        // Fuzz the invariants across a wide spread of ages and boundary offsets.
        for ageMinutes in [0, 1, 2, 3, 5, 10, 30, 120] {
            for offsetMinutes in [-300, -120, -30, -5, -1, 0, 1, 30] {
                let current = segment(startedSecondsAgo: Double(ageMinutes) * 60)
                let plan = TimelineGuard.plan(
                    current: current,
                    boundaryAt: now.addingTimeInterval(Double(offsetMinutes) * 60),
                    now: now
                )
                if case let .openNew(closeAt, startAt) = plan {
                    XCTAssertEqual(closeAt, startAt)
                    XCTAssertLessThanOrEqual(closeAt, now, "age=\(ageMinutes) off=\(offsetMinutes)")
                    XCTAssertGreaterThanOrEqual(
                        closeAt.timeIntervalSince(current.start), 180,
                        "age=\(ageMinutes) off=\(offsetMinutes)"
                    )
                }
            }
        }
    }

    func test_freshStartIsNotBackdatedBeforeThePreviousEntryEnded() {
        let previousEnd = now.addingTimeInterval(-300)
        let plan = TimelineGuard.plan(
            current: nil,
            boundaryAt: now.addingTimeInterval(-900),
            now: now,
            previousEnd: previousEnd
        )
        XCTAssertEqual(plan, .startFresh(at: previousEnd))
    }
}
