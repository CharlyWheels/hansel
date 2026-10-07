import XCTest
import SwiftData
@testable import TimeTracker

@MainActor
final class TodoDeletionTests: XCTestCase {
    func test_deletingATodoTakesItsSubtasksAndKeepsEntries() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let parent = Todo(title: "Demo")
        let child = Todo(title: "Slides", parent: parent)
        let grandchild = Todo(title: "Logo", parent: child)
        [parent, child, grandchild].forEach(ctx.insert)
        let entry = TimeEntry(title: "work", startAt: Date().addingTimeInterval(-600), endAt: Date(), linkedTodo: child)
        ctx.insert(entry)
        try ctx.save()

        XCTAssertEqual(TodoDeletion.descendants(of: parent).count, 2)
        let message = TodoDeletion.message(for: parent)
        XCTAssertTrue(message.contains("2 subtasks"), message)
        XCTAssertTrue(message.contains("1 time entry keeps its time"), message)

        TodoDeletion.delete(parent, context: ctx)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Todo>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TimeEntry>()), 1)
        XCTAssertNil(entry.linkedTodo)
    }
}
