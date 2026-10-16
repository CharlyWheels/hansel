import Foundation
import SwiftData

/// One thing that happened about the user's work, from any source: a meeting, a Slack
/// thread, an email conversation, a Teams chat, a calendar event, a Confluence page.
///
/// Only a short summary and the facts that matter are kept, with a link to the original.
/// Meetings are made by Hansel from its own `MeetingRecord`s; everything else is sent by
/// the assistant that can reach those sources (`add_context_items` over MCP).
///
/// Links to the todo and customer are ids, like `MeetingRecord`, so this model adds no
/// inverse relationships to the existing ones.
@Model
final class ContextItem {
    @Attribute(.unique) var id: UUID
    /// "<source>:<external id>", so the same thread or meeting is one item, updated as
    /// it grows.
    @Attribute(.unique) var sourceKey: String
    var sourceRaw: String
    var externalID: String
    var url: String?
    var title: String
    var occurredAt: Date
    var participants: [String] = []
    /// The Slack or Teams channel it was in, when it was in one.
    var channel: String?
    /// One or two lines.
    var summary: String
    /// The facts and decisions worth keeping, for writing the todo's dossier.
    var details: String = ""

    var statusRaw: String
    var todoID: UUID?
    var customerID: UUID?
    /// 0…1: how sure the assignment is.
    var confidence: Double = 0
    var assignedByRaw: String = AssignedBy.none.rawValue
    /// Why it was assigned, or why it waits in the inbox.
    var reason: String = ""

    /// What the assistant suggested, kept to learn from the user's corrections.
    var suggestedTodoID: UUID?
    var suggestedCustomerID: UUID?
    var suggestedConfidence: Double?
    /// A customer the assistant named that is not in the list.
    var proposedCustomerName: String?

    /// What the content was made from, to re-read a meeting only when it changed.
    var sourceVersion: String?

    var createdAt: Date
    var updatedAt: Date
    /// Set when the user decided it in the inbox.
    var resolvedByUserAt: Date?

    enum Source: String, CaseIterable, Codable {
        case meeting, slack, email, teams, calendar, confluence, github, other

        var label: String {
            switch self {
            case .meeting: return "Meeting"
            case .slack: return "Slack"
            case .email: return "Email"
            case .teams: return "Teams"
            case .calendar: return "Calendar"
            case .confluence: return "Confluence"
            case .github: return "GitHub"
            case .other: return "Other"
            }
        }

        var systemImage: String {
            switch self {
            case .meeting: return "waveform"
            case .slack, .teams: return "bubble.left.and.bubble.right"
            case .email: return "envelope"
            case .calendar: return "calendar"
            case .confluence: return "doc.text"
            case .github: return "chevron.left.forwardslash.chevron.right"
            case .other: return "tray"
            }
        }
    }

    enum Status: String, CaseIterable {
        /// Belongs to a todo, or to a customer when no todo fits.
        case assigned
        /// Waiting for the user in the inbox.
        case unassigned
        case discarded
    }

    enum AssignedBy: String {
        case none
        /// Hansel's own signals: aliases, the meeting's todos.
        case rules
        /// The assistant's suggestion.
        case assistant
        /// Both, agreeing.
        case both
        case user
    }

    init(
        id: UUID = UUID(),
        source: Source,
        externalID: String,
        url: String? = nil,
        title: String,
        occurredAt: Date,
        summary: String,
        now: Date = Date()
    ) {
        self.id = id
        self.sourceKey = Self.key(source: source, externalID: externalID)
        self.sourceRaw = source.rawValue
        self.externalID = externalID
        self.url = url
        self.title = title
        self.occurredAt = occurredAt
        self.summary = summary
        self.statusRaw = Status.unassigned.rawValue
        self.createdAt = now
        self.updatedAt = now
    }

    static func key(source: Source, externalID: String) -> String { "\(source.rawValue):\(externalID)" }

    var source: Source {
        get { Source(rawValue: sourceRaw) ?? .other }
        set { sourceRaw = newValue.rawValue }
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .unassigned }
        set { statusRaw = newValue.rawValue }
    }

    var assignedBy: AssignedBy {
        get { AssignedBy(rawValue: assignedByRaw) ?? .none }
        set { assignedByRaw = newValue.rawValue }
    }

    /// The user's decision stands: a later update of the same thread changes its
    /// content, not where it belongs.
    var isUserDecided: Bool { resolvedByUserAt != nil }
}
