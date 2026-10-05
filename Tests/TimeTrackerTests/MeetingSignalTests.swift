import XCTest
@testable import TimeTracker

final class ConferenceCatalogTests: XCTestCase {

    func test_recognisesTheAppsInstalledOnThisMachine() {
        XCTAssertTrue(ConferenceCatalog.isConferenceApp("us.zoom.xos"))
        XCTAssertTrue(ConferenceCatalog.isConferenceApp("com.microsoft.teams2"))
        XCTAssertTrue(ConferenceCatalog.isConferenceApp("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(ConferenceCatalog.isConferenceApp("com.microsoft.VSCode"))
    }

    func test_googleMeetPWAMatchesByPrefix() {
        // Chrome PWAs get a hash-suffixed bundle id, so an exact match would never hit.
        XCTAssertTrue(ConferenceCatalog.isConferenceApp("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"))
    }

    func test_zoomTitleDistinguishesCallFromIdleApp() {
        XCTAssertEqual(ConferenceCatalog.titleIndicatesCall(bundleId: "us.zoom.xos", windowTitle: "Zoom Meeting"), true)
        XCTAssertEqual(ConferenceCatalog.titleIndicatesCall(bundleId: "us.zoom.xos", windowTitle: "Zoom"), false)
        XCTAssertEqual(ConferenceCatalog.titleIndicatesCall(bundleId: "us.zoom.xos", windowTitle: "Zoom Workplace"), false)
    }

    func test_appsWithUselessTitlesReturnNilRatherThanFalse() {
        // "No signal" must not be confused with "definitely not in a call" — these
        // apps rely on the microphone alone.
        XCTAssertNil(ConferenceCatalog.titleIndicatesCall(bundleId: "com.microsoft.teams2", windowTitle: "Microsoft Teams"))
        XCTAssertNil(ConferenceCatalog.titleIndicatesCall(bundleId: "com.tinyspeck.slackmacgap", windowTitle: "Slack | general"))
        XCTAssertNil(ConferenceCatalog.titleIndicatesCall(bundleId: "com.hnc.Discord", windowTitle: "#general"))
    }

    func test_conferenceURLsRequireARealRoom() {
        XCTAssertTrue(ConferenceCatalog.isConferenceURL("https://meet.google.com/abc-defg-hij"))
        XCTAssertTrue(ConferenceCatalog.isConferenceURL("https://nedap.zoom.us/j/123456789"))
        XCTAssertTrue(ConferenceCatalog.isConferenceURL("https://teams.microsoft.com/l/meetup-join/19%3ameeting"))
        XCTAssertTrue(ConferenceCatalog.isConferenceURL("https://app.slack.com/huddle/T123/C456"))

        // Landing pages and unrelated pages are not meetings.
        XCTAssertFalse(ConferenceCatalog.isConferenceURL("https://meet.google.com/"))
        XCTAssertFalse(ConferenceCatalog.isConferenceURL("https://zoom.us/pricing"))
        XCTAssertFalse(ConferenceCatalog.isConferenceURL("https://github.com/acme"))
        XCTAssertFalse(ConferenceCatalog.isConferenceURL(nil))
    }

    func test_vetoAppsAreRecognised() {
        XCTAssertTrue(ConferenceCatalog.isVetoApp("com.apple.VoiceMemos"))
        XCTAssertTrue(ConferenceCatalog.isVetoApp("com.loom.desktop"))
        XCTAssertFalse(ConferenceCatalog.isVetoApp("us.zoom.xos"))
    }
}

final class MeetingConfidenceTests: XCTestCase {

    func test_micAloneDoesNotReachTheMeetingThreshold() {
        // Something is capturing, but nothing says it's a meeting. Must not commit.
        var signals = MeetingSignals()
        signals.micActive = true
        XCTAssertLessThan(MeetingConfidence.evaluate(signals).confidence, MeetingConfidence.enterThreshold)
    }

    func test_micPlusZoomInCallWindowIsAMeeting() {
        var signals = MeetingSignals()
        signals.micActive = true
        signals.runningConferenceApps = ["us.zoom.xos"]
        signals.callTitleMatch = true
        XCTAssertGreaterThanOrEqual(
            MeetingConfidence.evaluate(signals).confidence, MeetingConfidence.enterThreshold
        )
    }

    func test_slackHuddleIsDetectedFromMicAndCalendarDespiteNoTitle() {
        // Huddles give no window title at all — the whole point of the mic signal.
        var signals = MeetingSignals()
        signals.micActive = true
        signals.runningConferenceApps = ["com.tinyspeck.slackmacgap"]
        signals.conferenceURLSeen = true
        XCTAssertGreaterThanOrEqual(
            MeetingConfidence.evaluate(signals).confidence, MeetingConfidence.enterThreshold
        )
    }

    func test_processAttributionOutweighsBareDeviceRead() {
        var bare = MeetingSignals()
        bare.micActive = true
        var attributed = bare
        attributed.micBundleIds = ["us.zoom.xos"]
        XCTAssertGreaterThan(
            MeetingConfidence.evaluate(attributed).confidence,
            MeetingConfidence.evaluate(bare).confidence
        )
    }

    func test_unknownAttributionIsNotTreatedAsNobody() {
        // nil means the OS won't say, which must not be read as "no one is capturing".
        var signals = MeetingSignals()
        signals.micActive = true
        signals.micBundleIds = nil
        signals.runningConferenceApps = ["us.zoom.xos"]
        signals.callTitleMatch = true
        XCTAssertGreaterThanOrEqual(
            MeetingConfidence.evaluate(signals).confidence, MeetingConfidence.enterThreshold
        )
    }

    func test_recordingAppVetoesAnOtherwiseConvincingScore() {
        // Loom holds the mic exactly like a meeting does.
        var signals = MeetingSignals()
        signals.micActive = true
        signals.runningConferenceApps = ["us.zoom.xos"]
        signals.callTitleMatch = true
        signals.vetoAppActive = true
        XCTAssertLessThan(
            MeetingConfidence.evaluate(signals).confidence, MeetingConfidence.enterThreshold
        )
    }

    func test_lockedScreenDiscountsTheScore() {
        var base = MeetingSignals()
        base.micActive = true
        base.runningConferenceApps = ["us.zoom.xos"]
        base.callTitleMatch = true
        var locked = base
        locked.isIdleOrLocked = true
        XCTAssertLessThan(
            MeetingConfidence.evaluate(locked).confidence,
            MeetingConfidence.evaluate(base).confidence
        )
    }

    func test_calendarAloneIsNeverEnough() {
        // The whole complaint: a scheduled event is a hypothesis, not evidence.
        var signals = MeetingSignals()
        signals.trustworthyMeetingInProgress = true
        XCTAssertLessThan(
            MeetingConfidence.evaluate(signals).confidence, MeetingConfidence.enterThreshold
        )
    }

    func test_evidenceIsReportedForTheUI() {
        var signals = MeetingSignals()
        signals.micActive = true
        signals.runningConferenceApps = ["us.zoom.xos"]
        let (_, evidence) = MeetingConfidence.evaluate(signals)
        XCTAssertTrue(evidence.contains { $0.signal == "mic" })
        XCTAssertTrue(evidence.contains { $0.signal == "app.running" && $0.detail == "Zoom" })
    }
}
