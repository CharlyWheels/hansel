import XCTest
import SwiftData
@testable import TimeTracker

/// The timer's data-integrity paths: nothing may be left open, overlap, or touch a
/// deleted model.
@MainActor
final class TimerControllerTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
    }

    private func allEntries() -> [TimeEntry] {
        (try? context.fetch(FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startAt)]))) ?? []
    }

    func test_startWhileRunningClosesTheCurrentEntryInsteadOfOrphaningIt() {
        let ctrl = TimerController(modelContext: context)
        ctrl.startManual(title: "A")
        ctrl.startManual(title: "B")

        let open = allEntries().filter { $0.endAt == nil }
        XCTAssertEqual(open.map(\.title), ["B"])
    }

    func test_anEntryNobodyNamedTakesItsTodosTitleWhenStopped() {
        let ctrl = TimerController(modelContext: context)
        let todo = Todo(title: "Understand Lulu Harmony apps")
        context.insert(todo)
        ctrl.startManual()
        ctrl.runningEntry?.linkedTodo = todo
        ctrl.stop()
        ctrl.startManual()
        ctrl.stop()

        XCTAssertEqual(allEntries().map(\.title), ["Understand Lulu Harmony apps", "(untitled)"])
    }

    func test_undoSwitchReopensThePreviousEntryAndDeletesTheNewOne() {
        let ctrl = TimerController(modelContext: context)
        let now = Date()
        ctrl.startManual(title: "A")
        let a = ctrl.runningEntry!
        a.startAt = now.addingTimeInterval(-3600)

        let outcome = ctrl.switchTo(.init(title: "B"), boundaryAt: now.addingTimeInterval(-600),
                                    source: .aiSwitch, now: now)
        guard case .switched = outcome else { return XCTFail("\(outcome)") }
        let b = ctrl.runningEntry!

        XCTAssertTrue(ctrl.undoSwitch(previous: a, created: b))
        XCTAssertEqual(ctrl.runningEntry?.id, a.id)
        XCTAssertNil(a.endAt)
        XCTAssertEqual(allEntries().map(\.title), ["A"])
    }

    func test_undoIsRefusedOnceTheUserHasMovedOn() {
        let ctrl = TimerController(modelContext: context)
        let now = Date()
        ctrl.startManual(title: "A")
        let a = ctrl.runningEntry!
        a.startAt = now.addingTimeInterval(-3600)
        ctrl.switchTo(.init(title: "B"), boundaryAt: now.addingTimeInterval(-600),
                      source: .aiSwitch, now: now)
        let b = ctrl.runningEntry!
        ctrl.stop()
        ctrl.startManual(title: "C")

        XCTAssertFalse(ctrl.undoSwitch(previous: a, created: b))
        XCTAssertEqual(ctrl.runningEntry?.title, "C")
        XCTAssertNotNil(a.endAt)
    }

    func test_excludeAwayTimeSplitsAroundTheGap() {
        let ctrl = TimerController(modelContext: context)
        let now = Date()
        ctrl.startManual(title: "A")
        let a = ctrl.runningEntry!
        a.startAt = now.addingTimeInterval(-3600)

        let gapStart = now.addingTimeInterval(-1200)
        let gapEnd = now.addingTimeInterval(-60)
        ctrl.excludeAwayTime(from: gapStart, to: gapEnd)

        XCTAssertEqual(a.endAt, gapStart)
        let cont = ctrl.runningEntry!
        XCTAssertNotEqual(cont.id, a.id)
        XCTAssertEqual(cont.startAt, gapEnd)
        XCTAssertEqual(cont.title, "A")
        XCTAssertEqual(cont.previousEntryID, a.id)
    }

    func test_freshStartIsNeverBackdatedOverAStoppedEntry() {
        let ctrl = TimerController(modelContext: context)
        let now = Date()
        ctrl.startManual(title: "A")
        ctrl.runningEntry!.startAt = now.addingTimeInterval(-3600)
        ctrl.stop(at: now.addingTimeInterval(-300))

        let outcome = ctrl.switchTo(.init(title: "B"), boundaryAt: now.addingTimeInterval(-900),
                                    source: .aiSwitch, now: now)
        guard case .started = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(ctrl.runningEntry?.startAt, now.addingTimeInterval(-300))
    }

    func test_recoveryKeepsTheNewestOpenEntryAndClosesOlderOnesAtTheNextStart() throws {
        let now = Date()
        let old = TimeEntry(title: "old", startAt: now.addingTimeInterval(-7200))
        let new = TimeEntry(title: "new", startAt: now.addingTimeInterval(-1800))
        context.insert(new)
        context.insert(old)
        try context.save()

        let ctrl = TimerController(modelContext: context)
        XCTAssertEqual(ctrl.runningEntry?.title, "new")
        XCTAssertEqual(old.endAt, new.startAt, "the stray keeps its real time up to the next entry")
    }

    func test_runningEntryChangeNotifiesListeners() {
        let ctrl = TimerController(modelContext: context)
        var seen: [UUID?] = []
        ctrl.onRunningEntryChange { seen.append($0) }
        ctrl.startManual(title: "A")
        ctrl.stop()
        XCTAssertEqual(seen.count, 2)
        XCTAssertNil(seen.last!)
    }

    // MARK: - Day boundary

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func test_anEntryLeftBeforeMidnightEndsWhereTheUserWasLastSeen() {
        // Yesterday: "Teams chat with Tom Vieweger" ran from 16:31 until 10:58 the next day.
        let ctrl = TimerController(modelContext: context)
        ctrl.startFromAI(title: "Teams chat", startAt: at(14, 16, 31))
        let id = ctrl.runningEntry!.id

        let outcome = ctrl.enforceDayBoundary(lastPresence: at(14, 16, 36), now: at(15, 10, 43))

        XCTAssertEqual(outcome, .closed(entryID: id, dayEnd: at(15, 0)))
        XCTAssertFalse(ctrl.isRunning)
        XCTAssertEqual(allEntries().map(\.endAt), [at(14, 16, 36)])
    }

    func test_workPastMidnightIsSplitAtEachMidnightAndCarriesOn() {
        let ctrl = TimerController(modelContext: context)
        ctrl.startManual(title: "Release")
        ctrl.runningEntry!.startAt = at(13, 22)

        let outcome = ctrl.enforceDayBoundary(lastPresence: at(15, 1), now: at(15, 1))

        XCTAssertEqual(outcome, .split(count: 2))
        let entries = allEntries()
        XCTAssertEqual(entries.map(\.startAt), [at(13, 22), at(14, 0), at(15, 0)])
        XCTAssertEqual(entries.map(\.endAt), [at(14, 0), at(15, 0), nil])
        XCTAssertEqual(Set(entries.map(\.title)), ["Release"])
        XCTAssertEqual(ctrl.runningEntry?.id, entries.last?.id)
    }

    func test_anEntryWithinOneDayIsLeftAlone() {
        let ctrl = TimerController(modelContext: context)
        ctrl.startFromAI(title: "Today", startAt: at(15, 9))
        XCTAssertEqual(ctrl.enforceDayBoundary(lastPresence: at(15, 9, 30), now: at(15, 23, 59)), .none)
        XCTAssertTrue(ctrl.isRunning)
    }

    func test_anOverlongEntryIsPutUpForReviewEvenWhenStartedByHand() {
        let ctrl = TimerController(modelContext: context)
        ctrl.startManual(title: "Long")
        ctrl.runningEntry!.startAt = Date().addingTimeInterval(-11 * 3600)
        let long = ctrl.stop()!
        ctrl.startManual(title: "Short")
        let short = ctrl.stop()!

        XCTAssertTrue(long.needsReview)
        XCTAssertFalse(short.needsReview)
    }
}
