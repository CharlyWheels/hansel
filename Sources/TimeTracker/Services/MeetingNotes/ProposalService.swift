import Foundation
import Observation
import SwiftData

/// Turns imported meetings into proposals, and proposals into todos when accepted.
@Observable
@MainActor
final class ProposalService {
    /// Called after a meeting's proposals were made (possibly none), so the model can
    /// refine them or, when the summariser produced no action items list, extract them.
    @ObservationIgnored var onProposalsCreated: ((MeetingRecord, MeetingNotesDocument) -> Void)?
    /// Supplies what past decisions taught: a project to prefer for this meeting title,
    /// and a warning to show on its proposals. Filled in by `ProposalLearning`.
    @ObservationIgnored var learned: ((MeetingRecord) -> (projectID: UUID?, hint: String?))?

    @ObservationIgnored private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - From meetings

    func meetingImported(_ record: MeetingRecord, document: MeetingNotesDocument) {
        guard record.proposalsCreatedAt == nil else { return }
        // No insights yet means no action item list to read; wait for the file to
        // change, unless the meeting finished without a summary at all, which the model
        // may then cover from the transcript.
        if document.insights == nil {
            if record.status == "failed" || record.hasTranscript { onProposalsCreated?(record, document) }
            return
        }
        let learnedNow = learned?(record)
        let input = ProposalFactory.Input(
            record: record,
            document: document,
            resolution: MeetingContextResolver.resolve(record: record, learnedProjectID: learnedNow?.projectID,
                                                       context: modelContext),
            userNames: OwnerMatcher.userNames(),
            meetingHint: learnedNow?.hint
        )
        let existing = Set(proposals(forMeeting: record.id).map(\.sourceKey))
        let fresh = ProposalFactory.makeProposals(input).filter { !existing.contains($0.sourceKey) }
        fresh.forEach { modelContext.insert($0) }
        record.proposalsCreatedAt = Date()
        try? modelContext.save()
        AppLogger.log("meetings", level: .info, "proposals_created count=\(fresh.count)")
        onProposalsCreated?(record, document)
    }

    /// A meeting deleted in Meeting Notes takes its undecided proposals with it. Accepted
    /// ones already became todos and declined ones are kept to learn from.
    func meetingsRemoved(_ ids: [UUID]) {
        let ids = Set(ids)
        let pending = TodoProposal.Status.pending.rawValue
        let doomed = ((try? modelContext.fetch(FetchDescriptor<TodoProposal>(
            predicate: #Predicate { $0.statusRaw == pending }
        ))) ?? []).filter { ids.contains($0.meetingID) }
        doomed.forEach { modelContext.delete($0) }
        try? modelContext.save()
    }

    // MARK: - Decisions

    /// Creates the todo with the proposal's fields as they are now, edits included.
    @discardableResult
    func accept(_ proposal: TodoProposal, now: Date = Date()) -> Todo {
        let projectID = proposal.projectID
        let project = projectID.flatMap { id in
            try? modelContext.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first
        }
        let roots = ((try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []).filter { $0.parent == nil }
        let todo = Todo(
            title: proposal.title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: proposal.notes.isEmpty ? nil : proposal.notes,
            dueAt: proposal.dueAt,
            sortOrder: (roots.map(\.sortOrder).max() ?? -1) + 1,
            relatedProject: project
        )
        modelContext.insert(todo)
        proposal.status = .accepted
        proposal.resolvedAt = now
        proposal.acceptedTodoID = todo.id
        try? modelContext.save()
        AppLogger.log("meetings", level: .info, "proposal_accepted edited=\(proposal.title != proposal.suggestedTitle)")
        return todo
    }

    func decline(_ proposal: TodoProposal, now: Date = Date()) {
        proposal.status = .declined
        proposal.resolvedAt = now
        try? modelContext.save()
        AppLogger.log("meetings", level: .info, "proposal_declined")
    }

    func declineAll(forMeeting meetingID: UUID) {
        proposals(forMeeting: meetingID).filter(\.isPending).forEach { decline($0) }
    }

    /// Back to the inbox, for a decline made by mistake.
    func restore(_ proposal: TodoProposal) {
        guard proposal.status == .declined else { return }
        proposal.status = .pending
        proposal.resolvedAt = nil
        try? modelContext.save()
    }

    // MARK: - Queries

    func proposals(forMeeting meetingID: UUID) -> [TodoProposal] {
        let descriptor = FetchDescriptor<TodoProposal>(
            predicate: #Predicate { $0.meetingID == meetingID },
            sortBy: [SortDescriptor(\TodoProposal.sourceKey)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
