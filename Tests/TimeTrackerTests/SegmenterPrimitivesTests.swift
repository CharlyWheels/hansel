import XCTest
@testable import TimeTracker

final class SimilarityTests: XCTestCase {
    func test_cosine_identicalVectorsAreOne() {
        XCTAssertEqual(Similarity.cosine(["a": 1, "b": 2], ["a": 1, "b": 2]), 1, accuracy: 1e-9)
    }
    func test_cosine_isScaleInvariant() {
        XCTAssertEqual(Similarity.cosine(["a": 1, "b": 2], ["a": 10, "b": 20]), 1, accuracy: 1e-9)
    }
    func test_cosine_disjointVectorsAreZero() {
        XCTAssertEqual(Similarity.cosine(["a": 1], ["b": 1]), 0, accuracy: 1e-9)
    }
    func test_cosine_bothEmptyMeansUnchanged() {
        // "No evidence on either side" must read as "nothing changed", not "changed
        // completely" — otherwise every native-app window would look like a boundary.
        XCTAssertEqual(Similarity.cosine([:], [:]), 1)
    }
    func test_cosine_oneEmptyIsZero() {
        XCTAssertEqual(Similarity.cosine(["a": 1], [:]), 0)
    }

    func test_weightedJaccard_penalisesAddedVocabularyToo() {
        // Superset should not score as "identical": new jargon means a new topic.
        let subset = Similarity.weightedJaccard(["a": 1], ["a": 1, "b": 1])
        XCTAssertEqual(subset, 0.5, accuracy: 1e-9)
    }
    func test_weightedJaccard_identicalIsOne() {
        XCTAssertEqual(Similarity.weightedJaccard(["a": 2, "b": 1], ["a": 2, "b": 1]), 1, accuracy: 1e-9)
    }
    func test_weightedJaccard_disjointIsZero() {
        XCTAssertEqual(Similarity.weightedJaccard(["a": 1], ["b": 1]), 0, accuracy: 1e-9)
    }

    func test_normalized_sumsToOne() {
        let n = Similarity.normalized(["a": 3, "b": 1])
        XCTAssertEqual(n.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(n["a"] ?? 0, 0.75, accuracy: 1e-9)
    }
    func test_normalized_emptyStaysEmpty() {
        XCTAssertTrue(Similarity.normalized([:]).isEmpty)
        XCTAssertTrue(Similarity.normalized(["a": 0]).isEmpty)
    }
}

final class TitleTokenizerTests: XCTestCase {
    func test_dropsChromeAndShortAndNumericTokens() {
        let tokens = TitleTokenizer.tokens(from: "Untitled — Google Chrome — 2026 — ok — Acme")
        XCTAssertEqual(tokens, ["acme"])
    }
    func test_lowercasesAndDeduplicates() {
        XCTAssertEqual(TitleTokenizer.tokens(from: "Acme acme ACME report"), ["acme", "report"])
    }
    func test_nilAndEmptyYieldNoTokens() {
        XCTAssertTrue(TitleTokenizer.tokens(from: nil).isEmpty)
        XCTAssertTrue(TitleTokenizer.tokens(from: "").isEmpty)
    }
    func test_capsTokenCount() {
        let long = (1...40).map { "word\($0)x" }.joined(separator: " ")
        XCTAssertEqual(TitleTokenizer.tokens(from: long).count, TitleTokenizer.maximumTokensPerSample)
    }

    func test_hostKeyKeepsFirstPathSegment() {
        // The host alone is constant across every project on a SaaS tool; the first
        // path segment is what carries the identity.
        XCTAssertEqual(
            TitleTokenizer.hostKey(from: "https://acme.atlassian.net/browse/ACME-42"),
            "acme.atlassian.net/browse"
        )
    }
    func test_hostKeyStripsWWWAndHandlesBareHost() {
        XCTAssertEqual(TitleTokenizer.hostKey(from: "https://www.example.com"), "example.com")
    }
    func test_hostKeyNilForNonURLs() {
        XCTAssertNil(TitleTokenizer.hostKey(from: nil))
        XCTAssertNil(TitleTokenizer.hostKey(from: ""))
        XCTAssertNil(TitleTokenizer.hostKey(from: "not a url"))
    }
}

final class AttendanceFilterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        showsAsFree: Bool = false,
        attendance: Attendance = .accepted,
        attendeeCount: Int = 0,
        hasConferenceURL: Bool = false,
        durationHours: Double = 1,
        calendarId: String = "cal-work"
    ) -> MeetingWindow {
        MeetingWindow(
            eventId: "e", title: "t",
            start: start, end: start.addingTimeInterval(durationHours * 3600),
            isAllDay: isAllDay, isCancelled: isCancelled, showsAsFree: showsAsFree,
            attendance: attendance, attendeeCount: attendeeCount,
            hasConferenceURL: hasConferenceURL, calendarId: calendarId
        )
    }

    func test_hardRejections() {
        XCTAssertEqual(AttendanceFilter.weight(for: meeting(isCancelled: true)), 0)
        XCTAssertEqual(AttendanceFilter.weight(for: meeting(isAllDay: true)), 0)
        XCTAssertEqual(AttendanceFilter.weight(for: meeting(attendance: .declined)), 0)
        XCTAssertEqual(AttendanceFilter.weight(for: meeting(durationHours: 9)), 0)
        XCTAssertEqual(AttendanceFilter.weight(for: meeting(durationHours: 0)), 0)
    }

    func test_calendarAllowListExcludesEverythingElse() {
        // Birthdays, holidays and subscribed calendars must never start a timer.
        XCTAssertEqual(
            AttendanceFilter.weight(for: meeting(calendarId: "cal-birthdays"),
                                    allowedCalendarIds: ["cal-work"]),
            0
        )
        XCTAssertGreaterThan(
            AttendanceFilter.weight(for: meeting(calendarId: "cal-work"),
                                    callShareAfter: 1,
                                    allowedCalendarIds: ["cal-work"]),
            0
        )
    }

    func test_freeHoldScoresFarBelowARealMeeting() {
        let hold = AttendanceFilter.weight(for: meeting(showsAsFree: true), callShareAfter: 1)
        let real = AttendanceFilter.weight(
            for: meeting(attendeeCount: 5, hasConferenceURL: true), callShareAfter: 1
        )
        XCTAssertLessThan(hold, real)
        XCTAssertLessThan(hold, 0.4)
    }

    func test_acceptedButNotAttendedIsDiscounted() {
        // The direct fix for "it follows the calendar too much".
        let attended = AttendanceFilter.weight(for: meeting(attendeeCount: 3), callShareAfter: 1.0)
        let absent = AttendanceFilter.weight(for: meeting(attendeeCount: 3), callShareAfter: 0.0)
        XCTAssertLessThan(absent, attended)
    }

    func test_unknownAttendanceIsNotPunished() {
        // isCurrentUser is unreliable on some CalDAV accounts; absence of an answer
        // must not be read as a decline.
        let unknown = AttendanceFilter.weight(for: meeting(attendance: .unknown), callShareAfter: 1)
        XCTAssertGreaterThan(unknown, 0)
    }

    func test_pendingInvitationScoresBelowAccepted() {
        let pending = AttendanceFilter.weight(for: meeting(attendance: .pending), callShareAfter: 1)
        let accepted = AttendanceFilter.weight(for: meeting(attendance: .accepted), callShareAfter: 1)
        XCTAssertLessThan(pending, accepted)
    }

    func test_corroborationThreshold() {
        XCTAssertTrue(AttendanceFilter.isCorroborated(callShareAfter: 0.5))
        XCTAssertFalse(AttendanceFilter.isCorroborated(callShareAfter: 0.49))
    }
}
