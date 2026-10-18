import Foundation
import SwiftData

/// Todos the user handed to agents, and the loop around them: an agent takes the next
/// one, works through its brief, and leaves progress, questions, actions to approve and
/// deliverables; the user answers in batches; the next agent run carries on from there.
///
/// Approval is enforced here, not trusted to the agent: an action needing the user's OK
/// is only handed back as approved once the user approved it in Hansel.
@MainActor
enum DelegationService {

    /// An agent run that has not reported for this long died; its todo goes back to the queue.
    static let staleWorkingSeconds: TimeInterval = 3 * 3600

    struct Rejection: Error { let message: String }

    // MARK: - The user

    static func delegate(_ todo: Todo, context: ModelContext, now: Date = Date()) throws {
        guard !todo.isExcludedFromContext else {
            throw Rejection(message: "This todo's customer is kept out of AI context, so agents cannot work on it.")
        }
        guard !todo.isCompleted else { throw Rejection(message: "This todo is already done.") }
        guard todo.delegation == .none else { return }
        todo.delegation = .queued
        todo.delegatedAt = now
        todo.delegationUpdatedAt = now
        try? context.save()
    }

    /// Takes the todo back; open questions and approvals are closed unanswered.
    static func undelegate(_ todo: Todo, context: ModelContext, now: Date = Date()) {
        todo.delegation = .none
        todo.delegationUpdatedAt = now
        for note in notes(for: todo, context: context) where note.needsUser {
            note.status = .closed
            note.resolvedAt = now
        }
        try? context.save()
    }

    static func approve(_ note: AgentNote, comment: String? = nil, context: ModelContext, now: Date = Date()) {
        resolve(note, status: .approved, answer: comment, context: context, now: now)
    }

    static func reject(_ note: AgentNote, reason: String?, context: ModelContext, now: Date = Date()) {
        resolve(note, status: .rejected, answer: reason, context: context, now: now)
    }

    static func answer(_ note: AgentNote, _ text: String, context: ModelContext, now: Date = Date()) {
        resolve(note, status: .answered, answer: text, context: context, now: now)
    }

    /// The deliverable is good: the todo is done and leaves the agents.
    static func accept(_ note: AgentNote, context: ModelContext, now: Date = Date()) {
        note.status = .accepted
        note.resolvedAt = now
        if let todo = todo(note.todoID, context: context) {
            todo.delegation = .none
            todo.delegationUpdatedAt = now
            HanselActions.setCompleted(todo, true, context: context, now: now)
        }
        try? context.save()
    }

    /// More work needed: back to the queue with the user's comment.
    static func sendBack(_ note: AgentNote, comment: String, context: ModelContext, now: Date = Date()) {
        resolve(note, status: .sentBack, answer: comment, context: context, now: now)
    }

    private static func resolve(_ note: AgentNote, status: AgentNote.Status, answer: String?,
                                context: ModelContext, now: Date) {
        note.status = status
        note.answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        note.resolvedAt = now
        // Nothing left waiting for the user: the agent can carry on.
        if let todo = todo(note.todoID, context: context), todo.delegation != .none,
           !notes(for: todo, context: context).contains(where: \.needsUser) {
            todo.delegation = .queued
            todo.delegationUpdatedAt = now
        }
        try? context.save()
    }

    // MARK: - The agent

    /// The todo an agent should work on next, now marked as being worked on: the oldest
    /// queued one, or one whose agent run died. Nil when there is nothing to do.
    static func takeNext(context: ModelContext, now: Date = Date()) -> Todo? {
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let candidates = todos.filter { todo in
            guard !todo.isCompleted, !todo.isExcludedFromContext else { return false }
            if todo.delegation == .queued { return true }
            let stale = (todo.delegationUpdatedAt ?? .distantPast) < now.addingTimeInterval(-staleWorkingSeconds)
            return todo.delegation == .working && stale
        }
        guard let next = candidates.min(by: { ($0.delegatedAt ?? .distantPast) < ($1.delegatedAt ?? .distantPast) }) else {
            return nil
        }
        next.delegation = .working
        next.delegationUpdatedAt = now
        try? context.save()
        return next
    }

    static func hasQueuedWork(context: ModelContext, now: Date = Date()) -> Bool {
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        return todos.contains { todo in
            !todo.isCompleted && !todo.isExcludedFromContext && (todo.delegation == .queued
                || (todo.delegation == .working
                    && (todo.delegationUpdatedAt ?? .distantPast) < now.addingTimeInterval(-staleWorkingSeconds)))
        }
    }

    /// Records what the agent left. Questions and approvals put the todo in `waiting`, a
    /// deliverable in `review`, progress keeps it `working`.
    @discardableResult
    static func record(_ kind: AgentNote.Kind, on todo: Todo, title: String, body: String, url: String?,
                       context: ModelContext, now: Date = Date()) throws -> AgentNote {
        guard todo.delegation != .none else {
            throw Rejection(message: "This todo is not delegated. Only work on todos from next_delegated_task.")
        }
        let note = AgentNote(todoID: todo.id, kind: kind, title: title, body: body, url: url, now: now)
        context.insert(note)
        switch kind {
        case .progress: todo.delegation = .working
        case .question, .approval: todo.delegation = .waiting
        case .deliverable: todo.delegation = .review
        }
        todo.delegationUpdatedAt = now
        try? context.save()
        return note
    }

    /// The agent acted on the user's decisions; they no longer need handing back.
    static func closeDecided(for todo: Todo, context: ModelContext, now: Date = Date()) {
        for note in notes(for: todo, context: context)
        where [.approved, .rejected, .answered, .sentBack].contains(note.status) {
            note.status = .closed
            note.resolvedAt = note.resolvedAt ?? now
        }
        try? context.save()
    }

    // MARK: - Reading

    static func notes(for todo: Todo, context: ModelContext) -> [AgentNote] {
        let id = todo.id
        return ((try? context.fetch(FetchDescriptor<AgentNote>(predicate: #Predicate { $0.todoID == id }))) ?? [])
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func todo(_ id: UUID, context: ModelContext) -> Todo? {
        (try? context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })))?.first
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
