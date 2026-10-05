import XCTest
import SwiftData
@testable import TimeTracker

/// An answer must only ever act on the entry the question was about.
@MainActor
final class FocusPromptCenterTests: XCTestCase {

    private var container: ModelContainer!
    private var ctrl: TimerController!
    private var store: FocusStore!
    private var center: FocusPromptCenter!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
        ctrl = TimerController(modelContext: context)
        store = FocusStore(modelContext: context, timerController: ctrl, meetingProvider: MeetingProvider())
        center = FocusPromptCenter(timerController: ctrl, store: store, modelContext: context)
    }

    private func proposal(at boundary: Date) -> FocusPolicy.Proposal {
        FocusPolicy.Proposal(boundaryAt: boundary, title: "Globex", role: nil, project: nil,
                             customer: nil, todo: nil, confidence: 0.8, rationale: "", evidence: "")
    }

    private func ask(at boundary: Date) -> UUID {
        let decision = FocusDecision(kind: .asked)
        store.record(decision)
        center.present(.ask(proposal(at: boundary)), decisionID: decision.id, previousTitle: "Acme")
        return decision.id
    }

    private func startOldEntry() -> TimeEntry {
        ctrl.startManual(title: "Acme")
        let entry = ctrl.runningEntry!
        entry.startAt = Date().addingTimeInterval(-3600)
        return entry
    }

    func test_stoppingTheEntryDropsTheQuestion() {
        _ = startOldEntry()
        let id = ask(at: Date().addingTimeInterval(-600))
        ctrl.stop()

        XCTAssertNil(center.pending)
        XCTAssertEqual(store.decision(id: id)?.userResponse, .superseded)
    }

    func test_lateAnswerAfterANewEntryStartedDoesNothing() {
        _ = startOldEntry()
        _ = ask(at: Date().addingTimeInterval(-600))
        ctrl.startManual(title: "Something new")
        center.applySwitch()

        XCTAssertEqual(ctrl.runningEntry?.title, "Something new")
        let titles = ((try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []).map(\.title)
        XCTAssertFalse(titles.contains("Globex"))
    }

    func test_applyThenUndoRestoresTheOriginalEntryAndLogsUndone() {
        let original = startOldEntry()
        let id = ask(at: Date().addingTimeInterval(-600))
        center.applySwitch()
        XCTAssertEqual(ctrl.runningEntry?.title, "Globex")
        XCTAssertNotNil(center.undoable)

        center.undoLastSwitch()
        XCTAssertEqual(ctrl.runningEntry?.id, original.id)
        XCTAssertNil(original.endAt)
        XCTAssertEqual(store.decision(id: id)?.userResponse, .undone)
    }

    func test_undoIsWithdrawnOnceTheSwitchedEntryStops() {
        _ = startOldEntry()
        _ = ask(at: Date().addingTimeInterval(-600))
        center.applySwitch()
        ctrl.stop()
        XCTAssertNil(center.undoable)
    }

    func test_newQuestionSupersedesTheOldOneInTheLog() {
        _ = startOldEntry()
        let first = ask(at: Date().addingTimeInterval(-900))
        _ = ask(at: Date().addingTimeInterval(-600))
        XCTAssertEqual(store.decision(id: first)?.userResponse, .superseded)
        XCTAssertNotNil(center.pending)
    }
}
