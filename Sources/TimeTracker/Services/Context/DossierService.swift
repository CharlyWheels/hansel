import Foundation
import SwiftData

/// The dossiers: one per todo and one per customer, in Markdown, kept up to date from
/// the context items. The assistant writes them (it has read the sources); Hansel
/// decides which are stale, hands over only what is new since each was written, and
/// checks what comes back: the sections are all there and the size stays bounded, so
/// old detail gets condensed instead of piling up.
///
/// A todo's dossier covers its own items and its subtasks'; a customer's is written
/// from its todos' dossiers and the items about the customer alone.
@MainActor
enum DossierService {

    static let sections = ["## Summary", "## Status", "## Decisions", "## People", "## Open questions",
                           "## Next steps", "## Sources"]
    static let todoLimit = 6000
    static let customerLimit = 8000

    enum Kind: String { case todo, customer }

    /// A dossier to (re)write and what is new for it.
    struct Work {
        var kind: Kind
        var id: UUID
        var name: String
        var customerName: String?
        var current: String
        var newItems: [ContextItem]
        /// For a customer: its open todos' dossiers, as they are now.
        var todoDossiers: [(path: String, dossier: String)] = []
        /// Pass back when saving: the newest thing this work includes.
        var through: Date
    }

    // MARK: - What is stale

    /// Todos first, so a customer is rewritten from fresh todo dossiers next time.
    static func pendingWork(context: ModelContext, limit: Int = 10) -> [Work] {
        let items = ((try? context.fetch(FetchDescriptor<ContextItem>())) ?? []).filter { $0.status == .assigned }
        let todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        let customers = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
        var work = todoWork(items: items, todos: todos)
        if work.count < limit {
            work += customerWork(items: items, todos: todos, customers: customers)
        }
        return Array(work.prefix(limit))
    }

    static func todoWork(items: [ContextItem], todos: [Todo]) -> [Work] {
        let byTodo = Dictionary(grouping: items.filter { $0.todoID != nil }, by: { $0.todoID! })
        return todos
            .filter { !$0.isCompleted && !$0.isExcludedFromContext }
            .compactMap { todo -> Work? in
                let ids = Set(subtree(todo).map(\.id))
                let mine = ids.flatMap { byTodo[$0] ?? [] }
                let fresh = mine.filter { $0.updatedAt > (todo.dossierThrough ?? .distantPast) }
                guard let newest = fresh.map(\.updatedAt).max() else { return nil }
                return Work(kind: .todo, id: todo.id, name: todo.breadcrumbPath,
                            customerName: todo.effectiveCustomer?.name, current: todo.dossier,
                            newItems: fresh.sorted { $0.occurredAt < $1.occurredAt }, through: newest)
            }
            .sorted { $0.name < $1.name }
    }

    static func customerWork(items: [ContextItem], todos: [Todo], customers: [Customer]) -> [Work] {
        customers.filter { !$0.excludedFromContext }.compactMap { customer -> Work? in
            let since = customer.dossierThrough ?? .distantPast
            let own = items.filter { $0.customerID == customer.id && $0.todoID == nil && $0.updatedAt > since }
            let theirs = todos.filter {
                $0.parent == nil && !$0.isCompleted && $0.effectiveCustomer?.id == customer.id && !$0.dossier.isEmpty
            }
            let changedTodos = theirs.compactMap(\.dossierUpdatedAt).filter { $0 > since }
            guard let newest = (own.map(\.updatedAt) + changedTodos).max() else { return nil }
            return Work(kind: .customer, id: customer.id, name: customer.name, customerName: customer.name,
                        current: customer.dossier, newItems: own.sorted { $0.occurredAt < $1.occurredAt },
                        todoDossiers: theirs.map { ($0.breadcrumbPath, $0.dossier) }, through: newest)
        }
        .sorted { $0.name < $1.name }
    }

    static func subtree(_ todo: Todo) -> [Todo] { [todo] + todo.subtasks.flatMap(subtree) }

    // MARK: - Saving

    struct Rejection: Error { let message: String }

    /// What is wrong with a dossier, or nil when it can be saved.
    static func problem(_ markdown: String, kind: Kind) -> String? {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = kind == .todo ? todoLimit : customerLimit
        if text.isEmpty { return "The dossier is empty." }
        if text.count > limit {
            return "The dossier has \(text.count) characters; the limit is \(limit). Condense the oldest detail (merge old decisions and sources into short lines, keep the links) and send it again."
        }
        let lines = Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = sections.filter { !lines.contains($0) }
        if !missing.isEmpty {
            return "Missing sections: \(missing.joined(separator: ", ")). Use exactly these headings, in this order: \(sections.joined(separator: ", ")). Write \"None.\" under one with nothing yet."
        }
        return nil
    }

    static func saveTodo(_ todo: Todo, markdown: String, through: Date?, context: ModelContext, now: Date = Date()) throws {
        guard !todo.isExcludedFromContext else { throw Rejection(message: "This todo is kept out of AI context.") }
        if let problem = problem(markdown, kind: .todo) { throw Rejection(message: problem) }
        todo.dossier = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        todo.dossierUpdatedAt = now
        if let through { todo.dossierThrough = max(through, todo.dossierThrough ?? .distantPast) }
        try? context.save()
    }

    static func saveCustomer(_ customer: Customer, markdown: String, through: Date?, context: ModelContext, now: Date = Date()) throws {
        guard !customer.excludedFromContext else { throw Rejection(message: "This customer is kept out of AI context.") }
        if let problem = problem(markdown, kind: .customer) { throw Rejection(message: problem) }
        customer.dossier = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        customer.dossierUpdatedAt = now
        if let through { customer.dossierThrough = max(through, customer.dossierThrough ?? .distantPast) }
        try? context.save()
    }

    /// The template the assistant fills, shown in the tools' descriptions.
    static var template: String {
        """
        ## Summary
        Two or three lines: what this is, for whom, and where it stands.
        ## Status
        Current state, blockers, latest news (dated).
        ## Decisions
        - YYYY-MM-DD: decision (who)
        ## People
        - Name — organisation/role — how they are involved
        ## Open questions
        - question (who should answer)
        ## Next steps
        - step — owner — due date if known
        ## Sources
        - YYYY-MM-DD [title](link) — one line
        """
    }
}
