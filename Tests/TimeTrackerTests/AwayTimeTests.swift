import XCTest
import SwiftData
@testable import TimeTracker

/// Time away from the Mac is not tracked.
@MainActor
final class AwayTimeTests: XCTestCase {

    private func decide(_ minutes: Double, locked: Bool = false, callStart: Bool = false, callNow: Bool = false)
        -> EntryCompletionService.AwayDecision {
        EntryCompletionService.awayDecision(
            awaySeconds: minutes * 60, sawLockOrSleep: locked,
            inCallWhenIdleBegan: callStart, inCallNow: callNow,
            minAwaySeconds: 120, longAwaySeconds: 3600
        )
    }

    func test_shortAbsenceIsRemovedAndLongOneStops() {
        XCTAssertEqual(decide(1, locked: true), .ignore)
        XCTAssertEqual(decide(15, locked: true), .remove)
        XCTAssertEqual(decide(13 * 60, locked: true), .stop, "overnight must never keep running")
    }

    func test_noInputWithTheScreenUnlockedIsOnlyAsked() {
        // Reading for six minutes without touching anything split an afternoon into
        // seven entries.
        XCTAssertEqual(decide(1), .ignore)
        XCTAssertEqual(decide(6), .ask)
        XCTAssertEqual(decide(90), .ask, "not even a long one closes the entry by itself")
    }

    func test_lockedScreenIsAwayEvenIfTheDetectorSaysCall() {
        // Yesterday: the detector still said "in a meeting" when the screen was locked.
        XCTAssertEqual(decide(180, locked: true, callStart: true, callNow: true), .stop)
    }

    func test_listeningOnACallWithTheScreenOnIsPresent() {
        XCTAssertEqual(decide(20, callStart: true, callNow: true), .presentOnCall)
        XCTAssertEqual(decide(20, locked: true, callStart: true, callNow: false), .remove)
        XCTAssertEqual(decide(20, callStart: true, callNow: false), .ask, "the call must still be on")
    }

    func test_keepThatTimeRestoresTheSplit() throws {
        let container = try AppModelContainer.inMemory()
        let ctrl = TimerController(modelContext: container.mainContext)
        let now = Date()
        ctrl.startManual(title: "A")
        let original = ctrl.runningEntry!
        original.startAt = now.addingTimeInterval(-3600)
        guard case let .split(originalID, continuationID)? =
                ctrl.excludeAwayTime(from: now.addingTimeInterval(-1200), to: now.addingTimeInterval(-60)) else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(originalID, original.id)
        let continuation = ctrl.runningEntry!
        XCTAssertEqual(continuation.id, continuationID)
        XCTAssertTrue(ctrl.undoSwitch(previous: original, created: continuation))
        XCTAssertNil(original.endAt)
        XCTAssertEqual(ctrl.runningEntry?.id, original.id)
    }

    func test_personalBlocksAreNotMeetings() {
        let start = Date()
        let personal = MeetingWindow(eventId: "e#1", title: "Música", start: start,
                                     end: start.addingTimeInterval(3600), attendance: .organizer)
        let call = MeetingWindow(eventId: "e#2", title: "Sync", start: start,
                                 end: start.addingTimeInterval(1800), attendeeCount: 3)
        let video = MeetingWindow(eventId: "e#3", title: "1:1", start: start,
                                  end: start.addingTimeInterval(1800), hasConferenceURL: true)
        XCTAssertFalse(personal.isRealMeeting)
        XCTAssertTrue(call.isRealMeeting)
        XCTAssertTrue(video.isRealMeeting)
    }

    // MARK: - Relaunch

    func test_theLaunchGapStartsWhereTheUserWasLastSeen() {
        let now = Date()
        let left = now.addingTimeInterval(-18 * 3600)
        let lastAlive = now.addingTimeInterval(-13 * 3600)
        let sample = now.addingTimeInterval(-20 * 3600)

        XCTAssertEqual(IdleMonitor.launchGap(orphanStart: left, lastAlive: lastAlive, lastSample: sample, now: now)?.start, left,
                       "an idle span the app never saw end is when the user left")
        XCTAssertEqual(IdleMonitor.launchGap(orphanStart: nil, lastAlive: lastAlive, lastSample: sample, now: now)?.start, lastAlive)
        XCTAssertEqual(IdleMonitor.launchGap(orphanStart: nil, lastAlive: nil, lastSample: sample, now: now)?.start, sample,
                       "installs from before the heartbeat fall back to the last sample")
        XCTAssertNil(IdleMonitor.launchGap(orphanStart: nil, lastAlive: nil, lastSample: nil, now: now))
    }

    func test_anOrphanedIdleSpanEndsWhenTheAppWasLastAlive() {
        let start = Date()
        XCTAssertEqual(IdleMonitor.orphanEnd(start: start, lastAlive: start.addingTimeInterval(5 * 3600)),
                       start.addingTimeInterval(5 * 3600), "not at its own start: that erased the absence")
        XCTAssertEqual(IdleMonitor.orphanEnd(start: start, lastAlive: nil), start)
    }

    func test_heartbeatIsThrottledAndPersists() {
        let defaults = UserDefaults(suiteName: "heartbeat-\(UUID().uuidString)")!
        let beat = Heartbeat(defaults: defaults, interval: 30)
        let t0 = Date()
        beat.beat(now: t0)
        beat.beat(now: t0.addingTimeInterval(10))
        XCTAssertEqual(Heartbeat(defaults: defaults).lastAliveAt, t0)
        beat.beat(now: t0.addingTimeInterval(31))
        XCTAssertEqual(Heartbeat(defaults: defaults).lastAliveAt, t0.addingTimeInterval(31))
    }
}
