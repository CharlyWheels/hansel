import XCTest
@testable import TimeTracker

final class JoinedMeetingResolverTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        _ title: String, at minutes: Double, for length: Double = 30,
        attendance: Attendance = .accepted, attendees: Int = 3, free: Bool = false
    ) -> MeetingWindow {
        MeetingWindow(eventId: title, title: title,
                      start: t0.addingTimeInterval(minutes * 60),
                      end: t0.addingTimeInterval((minutes + length) * 60),
                      showsAsFree: free, attendance: attendance, attendeeCount: attendees)
    }

    private func resolve(
        _ meetings: [MeetingWindow], now minutes: Double, callSince: Double = 0
    ) -> (meeting: MeetingWindow, since: Date)? {
        JoinedMeetingResolver.resolve(
            callSince: t0.addingTimeInterval(callSince * 60),
            meetings: meetings, now: t0.addingTimeInterval(minutes * 60), allowedCalendarIds: nil
        )
    }

    func test_unansweredInvitationStillNamesTheCallTheUserIsIn() {
        XCTAssertEqual(resolve([event("Customer sync", at: 0, attendance: .pending)], now: 5)?.meeting.title,
                       "Customer sync")
    }

    func test_declinedAndCancelledEventsNeverName() {
        XCTAssertNil(resolve([event("Skipped", at: 0, attendance: .declined)], now: 5))
    }

    func test_mostRecentlyStartedMeetingWins() {
        let result = resolve([event("First", at: 0, for: 60), event("Second", at: 30)], now: 31)
        XCTAssertEqual(result?.meeting.title, "Second")
    }

    func test_upcomingMeetingOnlyWhenNothingIsInProgress() {
        XCTAssertEqual(resolve([event("Next", at: 30)], now: 27)?.meeting.title, "Next")
        XCTAssertEqual(resolve([event("Now", at: 0), event("Next", at: 30)], now: 27)?.meeting.title, "Now")
    }

    func test_focusBlockDoesNotNameACall() {
        XCTAssertNil(resolve([event("Focus time", at: 0, attendees: 0, free: true)], now: 5))
    }

    func test_callStartIsKeptAsTheBoundary() {
        XCTAssertEqual(resolve([event("Standup", at: 0)], now: 5, callSince: 2)?.since,
                       t0.addingTimeInterval(120))
    }

    func test_noCalendarEventNamesNothing() {
        XCTAssertNil(resolve([], now: 5))
    }
}
