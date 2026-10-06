import XCTest
import SwiftData
@testable import TimeTracker

/// Proposals made from a meeting's action items, and what accepting or declining does.
@MainActor
final class TodoProposalTests: XCTestCase {

    // MARK: - Owner

    func test_owner_matchesAnyOfTheUsersNames() {
        let names = ["Carlos Rueda"]
        XCTAssertEqual(OwnerMatcher.classify(owner: "Carlos", userNames: names), .me)
        XCTAssertEqual(OwnerMatcher.classify(owner: "carlos and Jan", userNames: names), .me)
        XCTAssertEqual(OwnerMatcher.classify(owner: "Jan", userNames: names), .someoneElse)
    }

    func test_owner_missingOrCollectiveIsUndecided() {
        let names = ["Carlos"]
        XCTAssertEqual(OwnerMatcher.classify(owner: nil, userNames: names), .unknown)
        XCTAssertEqual(OwnerMatcher.classify(owner: "", userNames: names), .unknown)
        XCTAssertEqual(OwnerMatcher.classify(owner: "Team", userNames: names), .unknown)
        XCTAssertEqual(OwnerMatcher.classify(owner: "Unassigned", userNames: names), .unknown)
    }

    func test_owner_shortNamePartsDoNotMatch() {
        // "de" in "Jan de Vries" must not match "Carlos de la Rueda".
        XCTAssertEqual(OwnerMatcher.classify(owner: "Jan de Vries", userNames: ["Carlos de la Rueda"]), .someoneElse)
    }

    // MARK: - Factory

    func test_cleanTitle() {
        XCTAssertEqual(ProposalFactory.cleanTitle("send the plan to Acme."), "Send the plan to Acme")
        let long = String(repeating: "word ", count: 40)
        XCTAssertLessThanOrEqual(ProposalFactory.cleanTitle(long).count, 91)
        XCTAssertTrue(ProposalFactory.cleanTitle(long).hasSuffix("…"))
    }

    func test_makeProposals_fillsContextAndFlagsSomeoneElse() throws {
        let doc = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON())
        let record = MeetingRecord(id: doc.id, title: doc.title, startedAt: doc.startedAt,
                                   folderPath: "/a/m", fileModifiedAt: Date())
        let projectID = UUID(), customerID = UUID()
        let input = ProposalFactory.Input(
            record: record, document: doc,
            resolution: .init(projectID: projectID, customerID: customerID, source: .timeEntry),
            userNames: ["Carlos"]
        )
        let proposals = ProposalFactory.makeProposals(input)

        XCTAssertEqual(proposals.map(\.title),
                       ["Send the revised migration plan to Acme", "Book the follow-up workshop", "Check licence costs"])
        XCTAssertEqual(proposals.map(\.likelyForSomeoneElse), [false, true, false])
        XCTAssertTrue(proposals.allSatisfy { $0.projectID == projectID && $0.customerID == customerID })
        XCTAssertEqual(proposals[0].timestampSeconds, 754)
        XCTAssertTrue(proposals[0].notes.contains("Roadmap planning"))
        XCTAssertTrue(proposals[0].notes.contains("12:34"))
        XCTAssertNil(proposals[2].owner, "an empty owner is no owner")
        XCTAssertEqual(proposals[0].suggestedTitle, proposals[0].title)
    }

    // MARK: - Resolution

    func test_resolve_prefersLearnedThenEntryThenPastThenAttendees() {
        let acme = Customer(name: "Acme")
        acme.emailDomains = "acme.com"
        let api = Project(name: "API", customer: acme)
        let web = Project(name: "Web", customer: acme)
        let other = Project(name: "Internal")
        let all = [api, web, other]
        let entry = TimeEntry(title: "x", project: web)

        func resolve(learned: UUID? = nil, entry: TimeEntry? = nil, past: Project? = nil) -> MeetingContextResolver.Resolution {
            MeetingContextResolver.resolve(title: "t", attendeeDomains: ["acme.com"], linkedEntry: entry,
                                           learnedProjectID: learned, pastEntry: (past, nil),
                                           projects: all, customers: [acme])
        }

        XCTAssertEqual(resolve(learned: other.id, entry: entry).projectID, other.id)
        XCTAssertEqual(resolve(entry: entry, past: api).projectID, web.id)
        XCTAssertEqual(resolve(past: api).projectID, api.id)
        // Two Acme projects: the customer is known, the project is not guessed.
        let byAttendees = resolve()
        XCTAssertNil(byAttendees.projectID)
        XCTAssertEqual(byAttendees.customerID, acme.id)
        XCTAssertEqual(byAttendees.source, .attendees)
    }

    // MARK: - Service

    private func importSample(_ ctx: ModelContext, service: ProposalService) throws -> MeetingRecord {
        let doc = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON())
        let importer = MeetingImporter(modelContext: ctx)
        importer.onImported = { service.meetingImported($0, document: $1) }
        let entry = MeetingNotesArchive.Entry(folder: URL(fileURLWithPath: "/a/m"), modifiedAt: Date())
        importer.apply(loaded: [(entry, doc)], presentPaths: [entry.folder.path])
        // A second read of the same meeting (summary regenerated, renamed) must not
        // propose the same tasks again.
        importer.apply(loaded: [(entry, doc)], presentPaths: [entry.folder.path])
        return try XCTUnwrap(ctx.fetch(FetchDescriptor<MeetingRecord>()).first)
    }

    func test_import_createsProposalsOnce() throws {
        // Held for the whole test: a context outlived by its container crashes.
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let service = ProposalService(modelContext: ctx)
        let record = try importSample(ctx, service: service)
        XCTAssertEqual(service.proposals(forMeeting: record.id).count, 3)
        XCTAssertNotNil(record.proposalsCreatedAt)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Todo>()), 0, "nothing reaches the todo list unasked")
    }

    func test_accept_createsATodoWithTheEditedFields() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let project = Project(name: "Migration")
        ctx.insert(project)
        let existing = Todo(title: "Older", sortOrder: 4)
        ctx.insert(existing)
        try ctx.save()
        let service = ProposalService(modelContext: ctx)
        let record = try importSample(ctx, service: service)
        let proposal = try XCTUnwrap(service.proposals(forMeeting: record.id).first)

        proposal.title = "Send migration plan"
        proposal.projectID = project.id
        let due = Date(timeIntervalSince1970: 2_000_000_000)
        proposal.dueAt = due
        let todo = service.accept(proposal)

        XCTAssertEqual(todo.title, "Send migration plan")
        XCTAssertEqual(todo.relatedProject?.id, project.id)
        XCTAssertEqual(todo.dueAt, due)
        XCTAssertEqual(todo.sortOrder, 5, "lands at the end of the list")
        XCTAssertTrue(todo.notes?.contains("Roadmap planning") ?? false)
        XCTAssertEqual(proposal.status, .accepted)
        XCTAssertEqual(proposal.acceptedTodoID, todo.id)
        XCTAssertNotEqual(proposal.title, proposal.suggestedTitle, "the correction is kept to learn from")
    }

    func test_declineAndRestore() throws {
        // Held for the whole test: a context outlived by its container crashes.
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let service = ProposalService(modelContext: ctx)
        let record = try importSample(ctx, service: service)
        let proposal = try XCTUnwrap(service.proposals(forMeeting: record.id).first)
        service.decline(proposal)
        XCTAssertEqual(proposal.status, .declined)
        service.restore(proposal)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertNil(proposal.resolvedAt)
    }

    func test_removedMeeting_dropsOnlyUndecidedProposals() throws {
        // Held for the whole test: a context outlived by its container crashes.
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let service = ProposalService(modelContext: ctx)
        let record = try importSample(ctx, service: service)
        let all = service.proposals(forMeeting: record.id)
        service.accept(all[0])
        service.decline(all[1])

        service.meetingsRemoved([record.id])

        let left = try ctx.fetch(FetchDescriptor<TodoProposal>()).map(\.status)
        XCTAssertEqual(Set(left), [.accepted, .declined])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Todo>()), 1)
    }
}
