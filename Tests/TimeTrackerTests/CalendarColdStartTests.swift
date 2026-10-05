import XCTest
@testable import TimeTracker

/// When a calendar event may start the timer from cold, and from when.
@MainActor
final class CalendarColdStartTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(
        id: String = "evt#1",
        startedAgo: TimeInterval,
        lasting: TimeInterval = 3600,
        attendance: Attendance = .accepted,
        free: Bool = false
    ) -> MeetingWindow {
        let start = now.addingTimeInterval(-startedAgo)
        return MeetingWindow(eventId: id, title: "Standup", start: start,
                             end: start.addingTimeInterval(lasting),
                             showsAsFree: free, attendance: attendance, attendeeCount: 3)
    }

    private func coldStart(_ meetings: [MeetingWindow], handled: Set<String> = [], latestEnd: Date? = nil) -> (MeetingWindow, Date)? {
        CalendarService.coldStart(meetings: meetings, now: now, handledIds: handled,
                                  latestEnd: latestEnd, allowedCalendarIds: nil)
    }

    func test_startsAtTheOccurrenceStartNotTheSeriesStart() {
        let m = meeting(startedAgo: 120)
        let result = coldStart([m])
        XCTAssertEqual(result?.1, m.start)
    }

    func test_eventThatBeganTooLongAgoDoesNotStart() {
        XCTAssertNil(coldStart([meeting(startedAgo: CalendarService.catchUpSeconds + 60, lasting: 7200)]))
    }

    func test_endedEventDoesNotStart() {
        XCTAssertNil(coldStart([meeting(startedAgo: 1200, lasting: 600)]))
    }

    func test_handledOccurrenceDoesNotStartAgain() {
        XCTAssertNil(coldStart([meeting(startedAgo: 60)], handled: ["evt#1"]))
    }

    func test_neverBackdatesOverTheLastClosedEntry() {
        let m = meeting(startedAgo: 900)
        let stoppedAt = now.addingTimeInterval(-300)
        XCTAssertEqual(coldStart([m], latestEnd: stoppedAt)?.1, stoppedAt)
    }

    func test_focusHoldAndUnansweredInviteDoNotStart() {
        XCTAssertNil(coldStart([meeting(startedAgo: 60, free: true)]))
        XCTAssertNil(coldStart([meeting(startedAgo: 60, attendance: .pending)]))
        XCTAssertNil(coldStart([meeting(startedAgo: 60, attendance: .declined)]))
    }

    func test_mostRecentlyStartedEventWins() {
        let older = meeting(id: "a#1", startedAgo: 1200, lasting: 7200)
        let newer = meeting(id: "b#1", startedAgo: 60)
        XCTAssertEqual(coldStart([older, newer])?.0.eventId, "b#1")
    }
}
