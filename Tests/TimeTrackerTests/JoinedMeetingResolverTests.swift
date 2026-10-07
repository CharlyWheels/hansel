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
        _ meetings: [MeetingWindow], now minutes: Double,
        recording: ActiveRecording? = nil, callSince: Double = 0
    ) -> (meeting: MeetingWindow, since: Date)? {
        JoinedMeetingResolver.resolve(
            callSince: t0.addingTimeInterval(callSince * 60), recording: recording,
            meetings: meetings, now: t0.addingTimeInterval(minutes * 60), allowedCalendarIds: nil
        )
    }

    func test_recordingPicksItsEventAmongOverlappingOnes() {
        let recording = ActiveRecording(slug: "cr-ss", startedAt: t0.addingTimeInterval(32 * 60),
                                        folderName: "1532-cr-ss-74236788")
        let result = resolve([event("Review Lulu apps", at: 30), event("CR <> SS", at: 30)],
                             now: 33, recording: recording)
        XCTAssertEqual(result?.meeting.title, "CR <> SS")
        XCTAssertEqual(result?.since, recording.startedAt)
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

    func test_unscheduledRecordedCallIsNamedAfterTheRecording() {
        let recording = ActiveRecording(slug: "teams-meeting", startedAt: t0, folderName: "0957-teams-meeting-62536EA2")
        let result = resolve([], now: 5, recording: recording)
        XCTAssertEqual(result?.meeting.title, "Teams meeting")
        XCTAssertEqual(result?.since, t0)
    }

    func test_noCalendarAndNoRecordingNamesNothing() {
        XCTAssertNil(resolve([], now: 5))
    }
}

final class MeetingRecordingProbeTests: XCTestCase {

    func test_slugComesFromTheFolderName() {
        XCTAssertEqual(MeetingRecordingProbe.slug(fromFolderName: "1602-meet-up-lp-797AA51A"), "meet-up-lp")
        XCTAssertEqual(MeetingRecordingProbe.slug(fromFolderName: "1549-cr-ss-74236788"), "cr-ss")
        XCTAssertNil(MeetingRecordingProbe.slug(fromFolderName: "notes"))
    }

    func test_slugifyMatchesMeetingNotes() {
        XCTAssertEqual(MeetingRecordingProbe.slugify("CR <> SS"), "cr-ss")
        XCTAssertEqual(MeetingRecordingProbe.slugify("Meet Up LP"), "meet-up-lp")
        XCTAssertEqual(MeetingRecordingProbe.slugify("RFID Stock API for AM"), "rfid-stock-api-for-am")
        XCTAssertEqual(MeetingRecordingProbe.slugify("Reunión de diseño"), "reunion-de-diseno")
    }

    func test_onlyTheNewestUnfinishedFolderIsARecording() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let day = MeetingRecordingProbe.dayFolders(root: root, now: now)[0]

        func folder(_ name: String, minutesAgo: Double, finished: Bool) throws {
            let url = day.appending(path: name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if finished { try Data("{}".utf8).write(to: url.appending(path: "meeting.json")) }
            try fm.setAttributes([.creationDate: now.addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
        }

        try folder("0947-meeting-3DA22AA3", minutesAgo: 120, finished: false)   // abandoned
        try folder("1030-standup-11111111", minutesAgo: 60, finished: true)
        XCTAssertNil(MeetingRecordingProbe.activeRecording(root: root, now: now))

        try folder("1130-cr-ss-74236788", minutesAgo: 3, finished: false)
        let recording = MeetingRecordingProbe.activeRecording(root: root, now: now)
        XCTAssertEqual(recording?.slug, "cr-ss")
    }
}
