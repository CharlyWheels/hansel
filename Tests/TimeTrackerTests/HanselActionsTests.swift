import XCTest
import SwiftData
@testable import TimeTracker

/// The shared edit paths the views and the MCP tools both use.
@MainActor
final class HanselActionsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
    }

    func test_addTodoAppendsAfterItsSiblingsAndIgnoresEmptyTitles() throws {
        let first = try XCTUnwrap(HanselActions.addTodo(title: "First", context: context))
        let second = try XCTUnwrap(HanselActions.addTodo(title: "  Second \n", context: context))
        let child = try XCTUnwrap(HanselActions.addTodo(title: "Child", parent: first, context: context))

        XCTAssertEqual(second.title, "Second")
        XCTAssertGreaterThan(second.sortOrder, first.sortOrder)
        XCTAssertEqual(child.parent?.id, first.id)
        XCTAssertEqual(child.sortOrder, 0, "a first subtask starts its own order")
        XCTAssertNil(HanselActions.addTodo(title: "   ", context: context))
    }

    func test_setCompletedStampsAndClearsTheCompletionDate() throws {
        let todo = try XCTUnwrap(HanselActions.addTodo(title: "Ship", context: context))
        HanselActions.setCompleted(todo, true, context: context)
        XCTAssertTrue(todo.isCompleted)
        XCTAssertNotNil(todo.completedAt)
        HanselActions.setCompleted(todo, false, context: context)
        XCTAssertNil(todo.completedAt)
    }

    func test_saveEntryRecachesBillableAndMarksItHumanConfirmed() throws {
        let controller = TimerController(modelContext: context)
        let customer = try XCTUnwrap(HanselActions.addCustomer(name: "Acme", context: context))
        let project = try XCTUnwrap(HanselActions.addProject(name: "Site", customer: customer, context: context))
        let role = try XCTUnwrap(HanselActions.addRole(name: "Dev", context: context))
        let entry = TimeEntry(title: "", startAt: Date().addingTimeInterval(-3600), endAt: Date(), source: .aiAutoStart)

        HanselActions.saveEntry(entry, insert: true, context: context, controller: controller) { e in
            e.title = "Build"
            e.project = project
            e.customer = customer
            e.role = role
        }

        XCTAssertEqual(entry.modelContext, context)
        XCTAssertTrue(entry.billableCached)
        XCTAssertTrue(entry.isHumanConfirmed)
    }

    func test_refreshBillableOnlyTouchesMatchingEntries() throws {
        let project = try XCTUnwrap(HanselActions.addProject(name: "P", context: context))
        let other = try XCTUnwrap(HanselActions.addProject(name: "Q", context: context))
        let a = TimeEntry(title: "a", endAt: Date(), project: project, billableCached: true)
        let b = TimeEntry(title: "b", endAt: Date(), project: other, billableCached: true)
        context.insert(a); context.insert(b)
        project.defaultBillable = false
        other.defaultBillable = false

        let id = project.id
        HanselActions.refreshBillable(context: context) { $0.project?.id == id }

        XCTAssertFalse(a.billableCached)
        XCTAssertTrue(b.billableCached)
    }
}
