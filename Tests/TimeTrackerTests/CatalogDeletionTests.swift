import XCTest
import SwiftData
@testable import TimeTracker

/// Deleting catalog rows must never delete or corrupt past time entries.
@MainActor
final class CatalogDeletionTests: XCTestCase {

    func test_deletingACustomerKeepsItsProjectsAndEntries() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let customer = Customer(name: "Acme")
        let project = Project(name: "API", customer: customer)
        ctx.insert(customer)
        ctx.insert(project)
        let entry = TimeEntry(title: "work", startAt: Date().addingTimeInterval(-3600), endAt: Date(),
                              project: project, customer: customer, billableCached: true)
        ctx.insert(entry)
        try ctx.save()
        XCTAssertEqual(customer.entries.count, 1)

        ctx.delete(customer)
        try ctx.save()

        let entries = try ctx.fetch(FetchDescriptor<TimeEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].customer)
        XCTAssertEqual(entries[0].project?.name, "API")
        XCTAssertTrue(entries[0].billableCached, "history keeps its billable flag")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Project>()), 1)
    }

    func test_deletingATodoClearsTheLinkOnEntries() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let todo = Todo(title: "Ship")
        ctx.insert(todo)
        let entry = TimeEntry(title: "work", linkedTodo: todo)
        ctx.insert(entry)
        try ctx.save()

        ctx.delete(todo)
        try ctx.save()
        XCTAssertNil(try ctx.fetch(FetchDescriptor<TimeEntry>()).first?.linkedTodo)
    }
}
