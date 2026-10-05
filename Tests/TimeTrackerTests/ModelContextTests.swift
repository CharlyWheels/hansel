import XCTest
import SwiftData
@testable import TimeTracker

/// What the model is given: examples, todos, and the record of what was sent.
@MainActor
final class ModelContextTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
    }

    private func closed(_ title: String, _ source: EntrySource, hours: Double = 1, project: Project? = nil) -> TimeEntry {
        let start = Date().addingTimeInterval(-hours * 3600 - 60)
        let entry = TimeEntry(title: title, startAt: start, endAt: start.addingTimeInterval(hours * 3600),
                              project: project, isConfirmed: true, source: source)
        ctx.insert(entry)
        return entry
    }

    func test_backfillConfirmsManualAndLabelledAIEntriesOnly() throws {
        let project = Project(name: "API")
        ctx.insert(project)
        let manual = closed("manual", .manual)
        let aiWithProject = closed("ai labelled", .aiAutoStart, project: project)
        let aiBare = closed("ai bare", .aiAutoStart)
        let calendar = closed("meeting", .calendar, project: project)
        try ctx.save()

        XCTAssertEqual(DataMaintenance.backfillHumanConfirmed(context: ctx), 2)
        XCTAssertTrue(manual.isHumanConfirmed)
        XCTAssertTrue(aiWithProject.isHumanConfirmed)
        XCTAssertFalse(aiBare.isHumanConfirmed)
        XCTAssertFalse(calendar.isHumanConfirmed)
    }

    func test_runawayCalendarEntriesAreDeletedAndRealOnesKept() throws {
        _ = closed("Paternity leave", .calendar, hours: 3000)
        _ = closed("Standup", .calendar, hours: 0.5)
        _ = closed("Long manual day", .manual, hours: 14)
        try ctx.save()

        XCTAssertEqual(DataMaintenance.deleteRunawayCalendarEntries(context: ctx), 1)
        let titles = try ctx.fetch(FetchDescriptor<TimeEntry>()).map(\.title).sorted()
        XCTAssertEqual(titles, ["Long manual day", "Standup"])
    }

    func test_maintenanceRunsOnlyOnce() throws {
        let defaults = UserDefaults(suiteName: "DataMaintenanceTests-\(UUID().uuidString)")!
        DataMaintenance.runPending(context: ctx, defaults: defaults)
        _ = closed("Paternity leave", .calendar, hours: 3000)
        try ctx.save()
        DataMaintenance.runPending(context: ctx, defaults: defaults)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TimeEntry>()), 1)
    }

    func test_proposedTodoIsResolvedWhenAskedNotWhenAnswered() throws {
        let ctrl = TimerController(modelContext: ctx)
        let store = FocusStore(modelContext: ctx, timerController: ctrl, meetingProvider: MeetingProvider())
        let first = Todo(title: "Write report", sortOrder: 0)
        let second = Todo(title: "Fix bug", sortOrder: 1)
        ctx.insert(first)
        ctx.insert(second)
        try ctx.save()

        let id = store.todoID(forKey: "T2")
        XCTAssertEqual(id, second.id)

        // The list changes before the user answers: "T2" would now be another todo.
        first.isCompleted = true
        ctx.insert(Todo(title: "New thing", sortOrder: 2))
        try ctx.save()

        let proposal = FocusPolicy.Proposal(boundaryAt: Date(), title: "Bug", role: nil, project: nil,
                                            customer: nil, todo: "T2", confidence: 0.8,
                                            rationale: "", evidence: "")
        XCTAssertEqual(store.plan(from: proposal, todoID: id).todo?.id, second.id)
    }

    func test_inspectorRecordsTheLastPromptAndResponse() async throws {
        struct FakeProvider: AIProvider {
            let id = UUID()
            let displayName = "fake"
            func complete(system: String, user: String, maxTokens: Int, effort: AIEffort) async throws -> String { "{\"ok\":true}" }
        }
        let text = try await FakeProvider().inspectedComplete(kind: .draft, system: "sys", user: "the user prompt")
        XCTAssertEqual(text, "{\"ok\":true}")
        let record = try XCTUnwrap(PromptInspector.shared.records[.draft])
        XCTAssertEqual(record.user, "the user prompt")
        XCTAssertEqual(record.response, "{\"ok\":true}")
    }
}
