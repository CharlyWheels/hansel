import Foundation
import SwiftData

/// What an agent working on a delegated todo leaves for the user: progress, a question,
/// an action waiting for approval, or a deliverable to review. Questions and approvals
/// stay open until the user answers; the agent picks up the answer on its next turn.
///
/// The todo is referenced by id, like `ContextItem`, so no inverse relationship is added.
@Model
final class AgentNote {
    @Attribute(.unique) var id: UUID
    var todoID: UUID
    var kindRaw: String
    var title: String
    /// Markdown: the progress, the question, the exact action (recipients and text), or
    /// what was delivered.
    var body: String = ""
    /// A draft, page or file the note is about.
    var url: String?
    var statusRaw: String = Status.open.rawValue
    /// The user's answer, or why they rejected the action or sent the work back.
    var answer: String?
    var createdAt: Date
    var resolvedAt: Date?

    enum Kind: String, CaseIterable {
        case progress, question, approval, deliverable
    }

    enum Status: String {
        /// Waiting for the user (questions, approvals, deliverables), or just logged (progress).
        case open
        case approved, rejected, answered
        /// A deliverable the user accepted, or one sent back for more work.
        case accepted, sentBack
        /// Done with: the agent has acted on the user's decision.
        case closed
    }

    init(id: UUID = UUID(), todoID: UUID, kind: Kind, title: String, body: String = "",
         url: String? = nil, now: Date = Date()) {
        self.id = id
        self.todoID = todoID
        self.kindRaw = kind.rawValue
        self.title = title
        self.body = body
        self.url = url
        self.statusRaw = (kind == .progress ? Status.closed : Status.open).rawValue
        self.createdAt = now
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .progress }
        set { kindRaw = newValue.rawValue }
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    /// The user has something to do about it.
    var needsUser: Bool { status == .open && kind != .progress }
}
