import XCTest
import SwiftData
@testable import TimeTracker

/// What past accept/decline decisions teach the next proposals.
@MainActor
final class ProposalLearningTests: XCTestCase {

    private func decision(
        _ meeting: String = "Weekly sync",
        accepted: Bool = true,
        at seconds: TimeInterval = 0,
        suggested: String = "Do it",
        final: String? = nil,
        suggestedProject: UUID? = nil,
        finalProject: UUID? = nil
    ) -> ProposalLearning.Decision {
        .init(meetingTitle: meeting, accepted: accepted, resolvedAt: Date(timeIntervalSince1970: seconds),
              suggestedTitle: suggested, finalTitle: final ?? suggested,
              suggestedProjectID: suggestedProject, finalProjectID: accepted ? finalProject : nil)
    }

    func test_recurringKey_ignoresDatesAndNumbers() {
        XCTAssertEqual(ProposalLearning.recurringKey("Weekly sync 12/10"), "weekly sync")
        XCTAssertEqual(ProposalLearning.recurringKey("Weekly Sync #43"), "weekly sync")
        XCTAssertEqual(ProposalLearning.recurringKey("Reunión semanal – Acme"), "reunión semanal acme")
    }

    func test_learnedProject_isTheLatestCorrection() {
        let a = UUID(), b = UUID(), c = UUID()
        let decisions = [
            decision("Weekly sync 1", at: 10, suggestedProject: a, finalProject: b),
            decision("Weekly sync 2", at: 20, suggestedProject: a, finalProject: c),
            // Accepted as suggested: not a correction, teaches nothing new.
            decision("Weekly sync 3", at: 30, suggestedProject: a, finalProject: a),
            decision("Other meeting", at: 40, suggestedProject: a, finalProject: b)
        ]
        XCTAssertEqual(ProposalLearning.learnedProjectID(forMeetingTitle: "Weekly sync 4", decisions: decisions), c)
        XCTAssertNil(ProposalLearning.learnedProjectID(forMeetingTitle: "Kick-off", decisions: decisions))
    }

    func test_learnedProject_ignoresDeclines() {
        let decisions = [decision(accepted: false, suggestedProject: UUID())]
        XCTAssertNil(ProposalLearning.learnedProjectID(forMeetingTitle: "Weekly sync", decisions: decisions))
    }

    func test_hint_onlyWhenEveryEarlierProposalWasDeclined() {
        let declines = (0..<3).map { decision(accepted: false, at: Double($0)) }
        XCTAssertEqual(ProposalLearning.meetingHint(forMeetingTitle: "Weekly sync", decisions: declines),
                       "You declined all 3 earlier proposals from this meeting.")
        XCTAssertNil(ProposalLearning.meetingHint(forMeetingTitle: "Weekly sync", decisions: declines + [decision()]))
        XCTAssertNil(ProposalLearning.meetingHint(forMeetingTitle: "Weekly sync", decisions: Array(declines.prefix(2))))
    }

    func test_examples_newestFirstWithoutRepeats() {
        let decisions = [
            decision(accepted: false, at: 1, suggested: "Update the wiki"),
            decision(accepted: false, at: 3, suggested: "update the wiki"),
            decision(accepted: false, at: 2, suggested: "Send minutes"),
            decision(at: 4, suggested: "Send the plan", final: "Send migration plan to Acme"),
            decision(at: 5, suggested: "Call Jan", final: "Call Jan ")
        ]
        let (declined, corrections) = ProposalLearning.examples(decisions: decisions)
        XCTAssertEqual(declined, ["update the wiki", "Send minutes"])
        XCTAssertEqual(corrections.map(\.to), ["Send migration plan to Acme"], "a whitespace-only edit is no correction")
    }

    // MARK: - End to end

    func test_correctedProjectIsUsedForTheNextInstanceOfTheMeeting() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let internalProject = Project(name: "Internal")
        let migration = Project(name: "Migration")
        ctx.insert(internalProject)
        ctx.insert(migration)
        try ctx.save()

        let service = ProposalService(modelContext: ctx)
        service.learned = { record in
            let decisions = ProposalLearning.decisions(context: ctx)
            return (ProposalLearning.learnedProjectID(forMeetingTitle: record.title, decisions: decisions),
                    ProposalLearning.meetingHint(forMeetingTitle: record.title, decisions: decisions))
        }

        // First week: the user moves the task to Migration while accepting it.
        let week1 = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON(id: UUID(), title: "Roadmap planning 1"))
        let r1 = MeetingRecord(id: week1.id, title: week1.title, startedAt: week1.startedAt, folderPath: "/a/1", fileModifiedAt: Date())
        ctx.insert(r1)
        service.meetingImported(r1, document: week1)
        let first = try XCTUnwrap(service.proposals(forMeeting: r1.id).first)
        XCTAssertNil(first.projectID)
        first.projectID = migration.id
        service.accept(first)

        // Second week: the same meeting's tasks come with Migration already filled in.
        let week2 = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON(id: UUID(), title: "Roadmap planning 2"))
        let r2 = MeetingRecord(id: week2.id, title: week2.title, startedAt: week2.startedAt, folderPath: "/a/2", fileModifiedAt: Date())
        ctx.insert(r2)
        service.meetingImported(r2, document: week2)
        XCTAssertTrue(service.proposals(forMeeting: r2.id).allSatisfy { $0.projectID == migration.id })
    }

    func test_projectChangedOnTheTodoAfterAcceptingCounts() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let later = Project(name: "Later")
        ctx.insert(later)
        let service = ProposalService(modelContext: ctx)
        let doc = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON())
        let record = MeetingRecord(id: doc.id, title: doc.title, startedAt: doc.startedAt, folderPath: "/a/m", fileModifiedAt: Date())
        ctx.insert(record)
        service.meetingImported(record, document: doc)
        let todo = service.accept(try XCTUnwrap(service.proposals(forMeeting: record.id).first))

        todo.relatedProject = later
        try ctx.save()

        let decisions = ProposalLearning.decisions(context: ctx)
        XCTAssertEqual(ProposalLearning.learnedProjectID(forMeetingTitle: doc.title, decisions: decisions), later.id)
    }

    func test_reset_keepsUndecidedProposalsAndTodos() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let service = ProposalService(modelContext: ctx)
        let doc = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON())
        let record = MeetingRecord(id: doc.id, title: doc.title, startedAt: doc.startedAt, folderPath: "/a/m", fileModifiedAt: Date())
        ctx.insert(record)
        service.meetingImported(record, document: doc)
        let all = service.proposals(forMeeting: record.id)
        service.accept(all[0])
        service.decline(all[1])

        ProposalLearning.reset(context: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<TodoProposal>()).map(\.status), [.pending])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Todo>()), 1)
        XCTAssertTrue(ProposalLearning.decisions(context: ctx).isEmpty)
    }
}
