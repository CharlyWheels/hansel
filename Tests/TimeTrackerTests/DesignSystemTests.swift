import XCTest
import SwiftData
@testable import TimeTracker

@MainActor
final class DesignSystemTests: XCTestCase {

    private func at(_ hour: Int, _ minute: Int = 0, day: Date = Date()) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func test_todaySummaryCountsClosedAndRunningEntriesOfToday() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let now = at(12)
        let billableProject = Project(name: "Client", defaultBillable: true)
        ctx.insert(billableProject)
        ctx.insert(TimeEntry(title: "yesterday", startAt: now.addingTimeInterval(-86_400), endAt: now.addingTimeInterval(-86_000)))
        ctx.insert(TimeEntry(title: "morning", startAt: at(9), endAt: at(10), project: billableProject, billableCached: true))
        ctx.insert(TimeEntry(title: "running", startAt: at(11)))
        try ctx.save()

        let today = TodaySummary.load(context: ctx, now: now)
        XCTAssertEqual(today.entryCount, 2)
        XCTAssertEqual(today.strip.trackedSeconds, 2 * 3600, accuracy: 1)
        XCTAssertEqual(today.billablePercent, 50)
        XCTAssertEqual(today.strip.blocks.filter(\.isRunning).count, 1)
    }

    func test_dayStripWidensToFitEarlyAndLateWork() {
        let day = at(12)
        let items = [DayStripModel.Item(id: UUID(), start: at(6, 30, day: day), end: at(7, 30, day: day), colorKey: "a"),
                     DayStripModel.Item(id: UUID(), start: at(20, day: day), end: at(21, 15, day: day), colorKey: "b")]
        let model = DayStripModel.make(items: items, day: day, now: at(22, day: day))
        XCTAssertEqual(Calendar.current.component(.hour, from: model.rangeStart), 6)
        XCTAssertEqual(Calendar.current.component(.hour, from: model.rangeEnd), 23)
        XCTAssertTrue(model.blocks.allSatisfy { $0.from >= 0 && $0.to <= 1 && $0.from < $0.to })
    }
}
