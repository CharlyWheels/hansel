import Foundation
import SwiftData

/// A task heard in a meeting, waiting for the user to accept or decline it.
///
/// Kept apart from `Todo` on purpose: proposals must not show up in the todo list, the
/// menu bar or the prompts that link entries to todos until the user says yes.
///
/// The `suggested…` fields keep what Hansel first proposed, so accepting with edits
/// leaves a record of the correction to learn from (`ProposalLearning`).
@Model
final class TodoProposal {
    @Attribute(.unique) var id: UUID
    var meetingID: UUID
    /// "<meetingID>#<n>", so the same item is never proposed twice.
    var sourceKey: String
    var meetingTitle: String
    var meetingStartedAt: Date
    var statusRaw: String

    var title: String
    var notes: String
    var dueAt: Date?
    var projectID: UUID?
    var customerID: UUID?

    /// The action item as the summariser wrote it.
    var evidence: String
    var owner: String?
    /// Seconds from the start of the recording.
    var timestampSeconds: Double?
    var likelyForSomeoneElse: Bool = false
    /// Who was speaking when the item came up, once speakers are known.
    var saidBy: String? = nil
    /// Why Hansel thinks so, or another short warning, shown on the row.
    var hint: String?
    var enrichmentRaw: String

    var suggestedTitle: String
    var suggestedProjectID: UUID?
    var suggestedDueAt: Date?

    var createdAt: Date
    var resolvedAt: Date?
    var acceptedTodoID: UUID?

    enum Status: String { case pending, accepted, declined }
    /// How the fields were filled: catalog rules only, or refined by the model.
    enum Enrichment: String { case rules, ai }

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        sourceKey: String,
        meetingTitle: String,
        meetingStartedAt: Date,
        title: String,
        notes: String = "",
        dueAt: Date? = nil,
        projectID: UUID? = nil,
        customerID: UUID? = nil,
        evidence: String,
        owner: String? = nil,
        timestampSeconds: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sourceKey = sourceKey
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.statusRaw = Status.pending.rawValue
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.projectID = projectID
        self.customerID = customerID
        self.evidence = evidence
        self.owner = owner
        self.timestampSeconds = timestampSeconds
        self.enrichmentRaw = Enrichment.rules.rawValue
        self.suggestedTitle = title
        self.suggestedProjectID = projectID
        self.suggestedDueAt = dueAt
        self.createdAt = createdAt
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var enrichment: Enrichment {
        get { Enrichment(rawValue: enrichmentRaw) ?? .rules }
        set { enrichmentRaw = newValue.rawValue }
    }

    var isPending: Bool { status == .pending }

    /// Undecided proposals, newest meeting first.
    static var pendingDescriptor: FetchDescriptor<TodoProposal> {
        let pending = Status.pending.rawValue
        return FetchDescriptor(
            predicate: #Predicate { $0.statusRaw == pending },
            sortBy: [SortDescriptor(\TodoProposal.meetingStartedAt, order: .reverse),
                     SortDescriptor(\TodoProposal.sourceKey)]
        )
    }

    /// Records the current fields as what Hansel suggests. Called after each automatic
    /// fill, so only the user's own edits differ from them afterwards.
    func markCurrentAsSuggested() {
        suggestedTitle = title
        suggestedProjectID = projectID
        suggestedDueAt = dueAt
    }
}
