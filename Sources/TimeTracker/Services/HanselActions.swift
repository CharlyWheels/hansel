import Foundation
import SwiftData

/// The edits a person can make, in one place, so the app's views and the MCP tools
/// that assistants call change data the same way: billable flags re-cached, sort
/// orders kept, the meeting following its entry's name.
@MainActor
enum HanselActions {

    // MARK: - Entries

    /// Saves an entry the user (or an assistant on their behalf) edited.
    ///
    /// Inserts a new entry before `edit` sets relationships, so they are set between
    /// models that already share a context. Saving by hand is a human vouching for
    /// the entry, which makes it eligible as a classification example.
    static func saveEntry(
        _ entry: TimeEntry,
        insert: Bool,
        context: ModelContext,
        controller: TimerController,
        edit: (TimeEntry) -> Void
    ) {
        if insert { context.insert(entry) }
        edit(entry)
        entry.refreshBillableCache()
        entry.isHumanConfirmed = true
        // Only an edit to the running entry should hold the arbiter off it.
        if entry.endAt == nil, controller.runningEntry?.id == entry.id { controller.noteManualEdit() }
        try? context.save()
        // A meeting shows the name its entry was corrected to.
        MeetingTitleSync.entrySaved(entry, context: context)
    }

    /// Re-caches the billable flag of every entry `matches` selects, after a default
    /// changed on a project, customer or role.
    static func refreshBillable(context: ModelContext, where matches: (TimeEntry) -> Bool) {
        let all = (try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []
        for entry in all where matches(entry) { entry.refreshBillableCache() }
        try? context.save()
    }

    // MARK: - Todos

    /// Adds a todo at the end of its siblings. Nil for an empty title.
    @discardableResult
    static func addTodo(
        title: String,
        notes: String? = nil,
        dueAt: Date? = nil,
        parent: Todo? = nil,
        project: Project? = nil,
        context: ModelContext
    ) -> Todo? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let siblings = parent?.subtasks
            ?? ((try? context.fetch(FetchDescriptor<Todo>())) ?? []).filter { $0.parent == nil }
        let todo = Todo(
            title: trimmed,
            notes: notes,
            dueAt: dueAt,
            sortOrder: (siblings.map(\.sortOrder).max() ?? -1) + 1,
            parent: parent,
            relatedProject: project
        )
        context.insert(todo)
        try? context.save()
        return todo
    }

    static func setCompleted(_ todo: Todo, _ completed: Bool, context: ModelContext, now: Date = Date()) {
        todo.isCompleted = completed
        todo.completedAt = completed ? now : nil
        try? context.save()
    }

    // MARK: - Catalog

    @discardableResult
    static func addProject(
        name: String,
        customer: Customer? = nil,
        defaultBillable: Bool = true,
        context: ModelContext
    ) -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = Project(name: trimmed, customer: customer, defaultBillable: defaultBillable)
        context.insert(project)
        try? context.save()
        return project
    }

    @discardableResult
    static func addCustomer(name: String, defaultBillable: Bool = true, context: ModelContext) -> Customer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let customer = Customer(name: trimmed, defaultBillable: defaultBillable)
        context.insert(customer)
        try? context.save()
        return customer
    }

    @discardableResult
    static func addRole(name: String, defaultBillable: Bool = true, context: ModelContext) -> Role? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let role = Role(name: trimmed, defaultBillable: defaultBillable)
        context.insert(role)
        try? context.save()
        return role
    }
}
