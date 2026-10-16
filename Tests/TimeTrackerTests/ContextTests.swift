import XCTest
import SwiftData
@testable import TimeTracker

/// Context collected from every source lands on the right todo or customer, or waits in
/// the inbox when Hansel's own signals and the assistant do not agree.
@MainActor
final class ContextTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var defaults: UserDefaults!
    private var service: ContextService!

    private var lulu: Customer!
    private var alvaro: Customer!
    private var personal: Customer!
    private var demo: Todo!
    private var supply: Todo!
    private var supplySub: Todo!
    private var visa: Todo!

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
        defaults = UserDefaults(suiteName: "ContextTests-\(UUID())")
        service = ContextService(modelContext: context, defaults: defaults)

        lulu = try XCTUnwrap(HanselActions.addCustomer(name: "Lululemon", context: context))
        lulu.aliases = "lulu, lululemon.com"
        alvaro = try XCTUnwrap(HanselActions.addCustomer(name: "Alvaro Moreno", context: context))
        alvaro.aliases = "AM, alvaromoreno.es, #alvaro-moreno"
        personal = try XCTUnwrap(HanselActions.addCustomer(name: "Personal", context: context))
        personal.excludedFromContext = true
        demo = HanselActions.addTodo(title: "Demo Clustag", customer: lulu, context: context)
        supply = HanselActions.addTodo(title: "Supply Chain", customer: alvaro, context: context)
        supplySub = HanselActions.addTodo(title: "Test EPC API", parent: supply, context: context)
        visa = HanselActions.addTodo(title: "Visa", customer: personal, context: context)
    }

    private var catalog: ContextService.Catalog { ContextService.Catalog(context: context) }

    private func classify(
        title: String = "Thread", summary: String = "", participants: [String] = [], channel: String? = nil,
        todo: UUID? = nil, customer: String? = nil, confidence: Double? = nil
    ) -> ContextClassifier.Decision {
        ContextClassifier.classify(
            .init(title: title, summary: summary, participants: participants, channel: channel,
                  suggestedTodoID: todo, suggestedCustomer: customer, suggestedConfidence: confidence),
            customers: catalog.customers, todos: catalog.openTodos
        )
    }

    // MARK: - Classifier

    func test_aliasesAloneFindTheCustomersOnlyOpenTodo() {
        let byDomain = classify(participants: ["me@nedap.com", "ana@lululemon.com"])
        XCTAssertEqual(byDomain.outcome, .assigned(todoID: demo.id, customerID: lulu.id))
        XCTAssertEqual(byDomain.assignedBy, .rules)

        let byChannel = classify(channel: "#Alvaro-Moreno")
        XCTAssertEqual(byChannel.outcome, .assigned(todoID: supply.id, customerID: alvaro.id))
    }

    func test_aCustomerWithSeveralOpenTodosGetsTheItemItself() {
        let other = HanselActions.addTodo(title: "Rollout", customer: lulu, context: context)
        XCTAssertNotNil(other)
        let decision = classify(participants: ["ana@lululemon.com"])
        XCTAssertEqual(decision.outcome, .assigned(todoID: nil, customerID: lulu.id))
    }

    func test_assistantAndAliasesAgreeingAssignsTheSubtask() {
        let decision = classify(participants: ["x@alvaromoreno.es"], todo: supplySub.id, confidence: 0.5)
        XCTAssertEqual(decision.outcome, .assigned(todoID: supplySub.id, customerID: alvaro.id))
        XCTAssertEqual(decision.assignedBy, .both)
    }

    func test_disagreementOrDoubtGoesToTheInbox() {
        let conflict = classify(participants: ["ana@lululemon.com"], todo: supply.id, confidence: 0.95)
        XCTAssertEqual(conflict.outcome, .inbox)
        XCTAssertEqual(conflict.suggestedTodoID, supply.id, "the suggestion is kept for the inbox")

        XCTAssertEqual(classify(todo: supply.id, confidence: 0.5).outcome, .inbox, "unsure and alone")
        XCTAssertEqual(classify(todo: supply.id, confidence: 0.8).outcome,
                       .assigned(todoID: supply.id, customerID: alvaro.id), "sure and alone")
        XCTAssertEqual(classify(todo: UUID(), confidence: 0.9).outcome, .inbox, "not an open todo")
        XCTAssertEqual(classify(participants: ["a@lululemon.com", "b@alvaromoreno.es"]).outcome, .inbox,
                       "two customers")
        let unknown = classify(customer: "Inditex", confidence: 0.9)
        XCTAssertEqual(unknown.outcome, .inbox)
        XCTAssertEqual(unknown.proposedCustomerName, "Inditex")
    }

    func test_aMentionAloneOnlySuggests() {
        let decision = classify(title: "Lulu demo prep")
        XCTAssertEqual(decision.outcome, .inbox)
        XCTAssertEqual(decision.suggestedCustomerID, lulu.id)
        XCTAssertEqual(classify(title: "I am late").suggestedCustomerID, nil, "acronyms only in capitals")
        XCTAssertEqual(classify(title: "AM integration", customer: "Alvaro Moreno", confidence: 0.6).outcome,
                       .assigned(todoID: supply.id, customerID: alvaro.id), "with the assistant agreeing it counts")
    }

    func test_personalMattersAreDropped() {
        XCTAssertEqual(classify(todo: visa.id, confidence: 0.9).outcome, .drop)
        XCTAssertEqual(classify(customer: "Personal", confidence: 0.9).outcome, .drop)
    }

    // MARK: - Service

    private func incoming(_ id: String, title: String = "Thread", participants: [String] = [],
                          todo: UUID? = nil, confidence: Double? = nil) -> ContextService.Incoming {
        .init(source: .slack, externalID: id, url: "https://slack/\(id)", title: title, occurredAt: Date(),
              participants: participants, channel: nil, summary: String(repeating: "s", count: 900),
              details: "Decided X", suggestedTodoID: todo, suggestedCustomer: nil, confidence: confidence, reason: "fits")
    }

    private func allItems() -> [ContextItem] { (try? context.fetch(FetchDescriptor<ContextItem>())) ?? [] }

    func test_ingestUpdatesTheSameThreadAndKeepsTheUsersDecision() throws {
        service.ingest([incoming("t1", participants: ["a@lululemon.com"])])
        let item = try XCTUnwrap(allItems().first)
        XCTAssertEqual(item.todoID, demo.id)
        XCTAssertEqual(item.summary.count, ContextService.summaryLimit, "clipped")

        service.assign(item, todo: supplySub)
        service.ingest([incoming("t1", title: "Thread, more replies", participants: ["a@lululemon.com"])])
        XCTAssertEqual(allItems().count, 1, "the same source and id is one item")
        XCTAssertEqual(item.title, "Thread, more replies")
        XCTAssertEqual(item.todoID, supplySub.id, "the user's decision stands")
        XCTAssertEqual(item.customerID, alvaro.id)
    }

    func test_personalItemsAreNotStoredAndAnEarlierCopyGoes() {
        service.ingest([incoming("p1", todo: demo.id, confidence: 0.9)])
        XCTAssertEqual(allItems().count, 1)
        let outcomes = service.ingest([incoming("p1", todo: visa.id, confidence: 0.9)])
        XCTAssertEqual(outcomes.first?.status, "skipped")
        XCTAssertTrue(allItems().isEmpty)
    }

    func test_collectionCursorStartsTwoWeeksBackAndOnlyMovesForward() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(service.since(.slack, now: now), now.addingTimeInterval(-14 * 86_400))
        service.markCollected(.slack, through: now.addingTimeInterval(-3600), now: now)
        service.markCollected(.slack, through: now.addingTimeInterval(-7200), now: now)
        XCTAssertEqual(service.since(.slack, now: now), now.addingTimeInterval(-3600))
        service.markCollected(.slack, through: now.addingTimeInterval(9999), now: now)
        XCTAssertEqual(service.since(.slack, now: now), now, "never in the future")
        XCTAssertEqual(service.since(.email, now: now), now.addingTimeInterval(-14 * 86_400), "per source")
    }

    func test_meetingsFollowTheTodosAcceptedFromThem() throws {
        let record = MeetingRecord(id: UUID(), title: "Teams meeting", startedAt: Date().addingTimeInterval(-3600),
                                   endedAt: Date(), folderPath: "/nowhere", fileModifiedAt: Date(),
                                   summary: "We reviewed the EPC API. Next steps agreed. More text.")
        context.insert(record)
        try context.save()

        service.syncMeetings()
        var item = try XCTUnwrap(allItems().first)
        XCTAssertEqual(item.source, .meeting)
        XCTAssertEqual(item.status, .unassigned, "nothing links it yet")
        XCTAssertEqual(item.summary, "We reviewed the EPC API. Next steps agreed.")

        let proposal = TodoProposal(meetingID: record.id, sourceKey: "\(record.id)#1", meetingTitle: record.title,
                                    meetingStartedAt: record.startedAt, title: "Test more", evidence: "Test more")
        context.insert(proposal)
        let accepted = ProposalService(modelContext: context).accept(proposal)
        HanselActions.moveTodo(accepted, under: supply, context: context)

        service.syncMeetings()
        item = try XCTUnwrap(allItems().first)
        XCTAssertEqual(item.status, .assigned)
        XCTAssertEqual(item.todoID, supply.id, "the root its tasks went under")

        service.meetingsRemoved([record.id])
        XCTAssertTrue(allItems().isEmpty)
    }

    func test_aliasCandidatesSkipTheUsersOwnPublicAndTakenDomains() throws {
        defaults.set("me@nedap.com", forKey: "calendar.myEmails")
        service.ingest([incoming("t9", participants: ["me@nedap.com", "x@gmail.com", "y@zara.com", "z@lululemon.com"])])
        let item = try XCTUnwrap(allItems().first)
        item.channel = "itx-rfid"
        XCTAssertEqual(service.aliasCandidates(for: item, customer: alvaro), ["zara.com", "#itx-rfid"])
        XCTAssertTrue(service.addAlias("zara.com", to: alvaro))
        XCTAssertFalse(service.addAlias("lululemon.com", to: alvaro), "another customer's")
        XCTAssertEqual(CustomerMatcher.domains(of: alvaro), ["alvaromoreno.es", "zara.com"])
    }
}
