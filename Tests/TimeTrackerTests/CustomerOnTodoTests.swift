import XCTest
import SwiftData
@testable import TimeTracker

/// Every todo works for one customer from a closed list: set on the top-level todo,
/// decided by its project when that has a customer, and never duplicated by spelling.
@MainActor
final class CustomerOnTodoTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
    }

    // MARK: - Aliases

    func test_aliasKindComesFromItsShape() {
        let aliases = CustomerMatcher.aliases(in: " Acme.com, @acme.co.uk, ITX, #Acme-Rollout, Jane@Acme.com, @jane, , ITX")
        XCTAssertEqual(aliases, [
            .init(kind: .domain, value: "acme.com"),
            .init(kind: .domain, value: "acme.co.uk"),
            .init(kind: .name, value: "itx"),
            .init(kind: .slackChannel, value: "acme-rollout"),
            .init(kind: .contact, value: "jane@acme.com"),
            .init(kind: .contact, value: "jane"),
        ])
        let acme = Customer(name: "Acme")
        acme.aliases = "acme.com, ITX, #rollout"
        XCTAssertEqual(CustomerMatcher.domains(of: acme), ["acme.com"])
    }

    func test_closedListRefusesAnotherSpellingOrAnAliasInUse() throws {
        let inditex = try XCTUnwrap(HanselActions.addCustomer(name: "Inditex", context: context))
        inditex.aliases = "ITX, inditex.com, #itx-rfid"

        XCTAssertNil(HanselActions.addCustomer(name: "inditex", context: context))
        XCTAssertNil(HanselActions.addCustomer(name: " I.T.X ", context: context), "an existing alias, spelled differently")
        XCTAssertEqual(HanselActions.customerConflict(name: "ITX", context: context)?.customerName, "Inditex")

        let other = try XCTUnwrap(HanselActions.addCustomer(name: "Globex", context: context))
        XCTAssertEqual(HanselActions.customerConflict(aliases: "globex.io, INDITEX.COM", excluding: other, context: context)?.term, "INDITEX.COM")
        XCTAssertNotNil(HanselActions.customerConflict(aliases: "#ITX-RFID", excluding: other, context: context))
        XCTAssertNotNil(HanselActions.customerConflict(aliases: "Inditex", excluding: other, context: context))
        XCTAssertNil(HanselActions.customerConflict(aliases: "globex.io, #globex", excluding: other, context: context))
        XCTAssertNil(HanselActions.customerConflict(name: "Inditex", aliases: "ITX", excluding: inditex, context: context),
                     "a customer does not clash with itself")
    }

    // MARK: - Todos

    func test_subtasksWorkForTheirRootsCustomerAndAProjectDecidesIt() throws {
        let lulu = try XCTUnwrap(HanselActions.addCustomer(name: "Lululemon", context: context))
        let acme = try XCTUnwrap(HanselActions.addCustomer(name: "Acme", context: context))
        let demo = try XCTUnwrap(HanselActions.addProject(name: "Demo", customer: lulu, context: context))
        let loose = try XCTUnwrap(HanselActions.addProject(name: "Loose", context: context))

        let root = try XCTUnwrap(HanselActions.addTodo(title: "Root", customer: acme, context: context))
        let child = try XCTUnwrap(HanselActions.addTodo(title: "Child", parent: root, customer: lulu, context: context))
        XCTAssertNil(child.customer, "a subtask keeps no customer of its own")
        XCTAssertEqual(child.effectiveCustomer?.id, acme.id)

        HanselActions.setTodoProject(root, demo, context: context)
        XCTAssertEqual(root.customer?.id, lulu.id, "the project's customer wins")
        XCTAssertEqual(child.effectiveCustomer?.id, lulu.id)

        HanselActions.setTodoCustomer(root, acme, context: context)
        XCTAssertNil(root.relatedProject, "another customer's project is dropped")
        XCTAssertEqual(root.effectiveCustomer?.id, acme.id)

        HanselActions.setTodoProject(root, loose, context: context)
        XCTAssertEqual(root.effectiveCustomer?.id, acme.id, "a project without a customer keeps the todo's")

        let fromProject = try XCTUnwrap(HanselActions.addTodo(title: "P", project: demo, customer: acme, context: context))
        XCTAssertEqual(fromProject.customer?.id, lulu.id)
    }

    func test_movingATodoDropsOrKeepsItsCustomer() throws {
        let acme = try XCTUnwrap(HanselActions.addCustomer(name: "Acme", context: context))
        let globex = try XCTUnwrap(HanselActions.addCustomer(name: "Globex", context: context))
        let parent = try XCTUnwrap(HanselActions.addTodo(title: "Parent", customer: acme, context: context))
        let todo = try XCTUnwrap(HanselActions.addTodo(title: "Todo", customer: globex, context: context))

        HanselActions.moveTodo(todo, under: parent, context: context)
        XCTAssertNil(todo.customer)
        XCTAssertEqual(todo.effectiveCustomer?.id, acme.id)

        HanselActions.moveTodo(todo, under: nil, context: context)
        XCTAssertEqual(todo.customer?.id, acme.id, "back at the top it keeps the customer it worked for")
    }

    func test_acceptedProposalCarriesItsCustomer() throws {
        let acme = try XCTUnwrap(HanselActions.addCustomer(name: "Acme", context: context))
        let proposal = TodoProposal(
            meetingID: UUID(), sourceKey: "m#1", meetingTitle: "Sync", meetingStartedAt: Date(),
            title: "Send deck", customerID: acme.id, evidence: "Send the deck"
        )
        context.insert(proposal)
        let todo = ProposalService(modelContext: context).accept(proposal)
        XCTAssertEqual(todo.customer?.id, acme.id)
        XCTAssertFalse(todo.isExcludedFromContext)

        acme.excludedFromContext = true
        XCTAssertTrue(todo.isExcludedFromContext)
    }
}
