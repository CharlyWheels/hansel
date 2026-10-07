import XCTest
@testable import TimeTracker

final class AnalyticsEngineTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private let api = UUID()

    private func entry(_ start: Date, _ end: Date, project: UUID? = nil, name: String? = nil,
                       billable: Bool = false, source: EntrySource = .manual, confirmed: Bool = true,
                       title: String = "") -> AnalyticsEngine.EntryFact {
        .init(id: UUID(), title: title, start: start, end: end, projectID: project, projectName: name,
              customerID: nil, customerName: nil, roleID: nil, roleName: nil, billable: billable,
              source: source, humanConfirmed: confirmed, todoTitle: nil)
    }

    /// Week of Mon 5 – Sun 11 Oct 2026.
    private var week: DateInterval { DateInterval(start: date(5, 0), end: date(12, 0)) }

    func test_summaryComparesWithThePreviousWeek() {
        var input = AnalyticsEngine.Input()
        input.entries = [
            entry(date(5, 9), date(5, 11), project: api, name: "API", billable: true),   // 2h billable
            entry(date(6, 9), date(6, 10)),                                              // 1h
            entry(date(6, 14), date(6, 15), source: .calendar),                          // 1h meeting
            entry(date(5, 9), date(5, 10)).withDay(-7, cal: cal),                        // Mon 28 Sep: previous week, 1h
        ]
        let s = AnalyticsEngine.snapshot(input, interval: week, calendar: cal).summary
        XCTAssertEqual(s.tracked.current, 4 * 3600)
        XCTAssertEqual(s.tracked.previous, 3600)
        XCTAssertEqual(s.tracked.change!, 3, accuracy: 1e-9)
        XCTAssertEqual(s.billableShare.current, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.workingDays, 2)
        XCTAssertEqual(s.perWorkingDay.current, 2 * 3600)
        XCTAssertEqual(s.meetingSeconds.current, 3600)
    }

    func test_daysSplitAtMidnightAndHeatmapStartsOnMonday() {
        let late = entry(date(5, 23), date(6, 1), project: api, name: "API")
        let days = AnalyticsEngine.perDay([late], calendar: cal)
        XCTAssertEqual(days.map(\.seconds), [3600, 3600])
        let heat = AnalyticsEngine.heatmap([late], calendar: cal)
        XCTAssertEqual(heat.first { $0.weekday == 1 && $0.hour == 23 }?.seconds, 3600, "Monday 23:00")
        XCTAssertEqual(heat.first { $0.weekday == 2 && $0.hour == 0 }?.seconds, 3600, "Tuesday 00:00")
    }

    func test_breakdownCarriesBillableShareAndPreviousPeriod() {
        let current = [entry(date(5, 9), date(5, 11), project: api, name: "API", billable: true),
                       entry(date(5, 11), date(5, 12))]
        let previous = [entry(date(1, 9), date(1, 10), project: api, name: "API")]
        let lines = AnalyticsEngine.breakdown(current, previous: previous, interval: week,
                                              previousInterval: week, by: .project)
        XCTAssertEqual(lines.first?.name, "API")
        XCTAssertEqual(lines.first?.billableShare ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(lines.first?.previousSeconds, 3600)
        XCTAssertEqual(lines.last?.name, "No project")
    }

    func test_focusFromSamples() {
        var input = AnalyticsEngine.Input()
        input.samples = [
            .init(timestamp: date(5, 9, 0), bundleId: "com.apple.dt.Xcode", appName: "Xcode", host: nil),
            .init(timestamp: date(5, 9, 1), bundleId: "com.apple.dt.Xcode", appName: "Xcode", host: nil),
            .init(timestamp: date(5, 9, 2), bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", host: nil),
            .init(timestamp: date(5, 9, 3), bundleId: "com.google.Chrome", appName: "Chrome", host: "github.com"),
        ]
        let focus = AnalyticsEngine.snapshot(input, interval: week, calendar: cal).focus
        XCTAssertEqual(focus.topApps.map(\.name).first, "Xcode")
        XCTAssertEqual(focus.communicationShare, 60.0 / 210.0, accuracy: 1e-6)
        XCTAssertEqual(focus.topSites.first?.name, "github.com")
        XCTAssertFalse(AnalyticsEngine.isWebsite("file:software"))
        XCTAssertFalse(AnalyticsEngine.isWebsite("newtab"))
    }

    func test_meetingsCountRecordedOnceAndTalkShare() {
        var input = AnalyticsEngine.Input()
        let meeting = UUID()
        input.entries = [entry(date(6, 10), date(6, 11), source: .calendar, title: "Sync")]
        input.meetings = [.init(id: meeting, title: "Sync", start: date(6, 10), end: date(6, 10, 45))]
        input.speakers = [.init(meetingID: meeting, personName: "Carlos", isMe: true, seconds: 600, onCall: false),
                          .init(meetingID: meeting, personName: "Pablo", isMe: false, seconds: 1800, onCall: true)]
        input.proposals = [.init(meetingID: meeting, status: .accepted, createdAt: date(6, 11)),
                           .init(meetingID: meeting, status: .declined, createdAt: date(6, 11))]
        let m = AnalyticsEngine.snapshot(input, interval: week, calendar: cal).meetings
        XCTAssertEqual(m.count, 1, "the calendar entry covering the recording is the same meeting")
        XCTAssertEqual(m.seconds, 45 * 60)
        XCTAssertEqual(m.myTalkShare ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m.people.first?.name, "Pablo")
        XCTAssertEqual(m.proposalsAccepted, 1)
        XCTAssertEqual(m.proposalsDeclined, 1)
    }

    func test_qualityShares() {
        var input = AnalyticsEngine.Input()
        input.entries = [entry(date(5, 9), date(5, 10), project: api, name: "API", confirmed: true),
                         entry(date(5, 10), date(5, 13), confirmed: false, title: "x").sourced(.aiAutoStart)]
        input.decisions = [.init(at: date(5, 11), kind: .asked, response: .keptCurrent),
                           .init(at: date(5, 12), kind: .asked, response: .switched)]
        let q = AnalyticsEngine.snapshot(input, interval: week, calendar: cal).quality
        XCTAssertEqual(q.unassignedShare, 0.75, accuracy: 1e-9)
        XCTAssertEqual(q.reviewedShare, 0.25, accuracy: 1e-9)
        XCTAssertEqual(q.questionsAccepted, 1)
        XCTAssertEqual(q.questionsRejected, 1)
        XCTAssertEqual(q.bySource.first?.name, "Started by AI")
    }

    func test_wholeMonthComparesWithThePreviousWholeMonth() {
        let october = DateInterval(start: date(1, 0), end: cal.date(byAdding: .month, value: 1, to: date(1, 0))!)
        let previous = AnalyticsEngine.previous(of: october, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: previous.start), 9)
        XCTAssertEqual(cal.component(.day, from: previous.start), 1)
    }
}

private extension AnalyticsEngine.EntryFact {
    func withDay(_ offset: Int, cal: Calendar) -> Self {
        .init(id: id, title: title, start: cal.date(byAdding: .day, value: offset, to: start)!,
              end: cal.date(byAdding: .day, value: offset, to: end)!, projectID: projectID,
              projectName: projectName, customerID: customerID, customerName: customerName, roleID: roleID,
              roleName: roleName, billable: billable, source: source, humanConfirmed: humanConfirmed,
              todoTitle: todoTitle)
    }

    func sourced(_ source: EntrySource) -> Self {
        .init(id: id, title: title, start: start, end: end, projectID: projectID, projectName: projectName,
              customerID: customerID, customerName: customerName, roleID: roleID, roleName: roleName,
              billable: billable, source: source, humanConfirmed: humanConfirmed, todoTitle: todoTitle)
    }
}
