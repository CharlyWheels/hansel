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

    /// Adds a todo at the end of its siblings. Nil for an empty title. `customer` is
    /// kept on top-level todos only: a subtask works for its root's customer.
    @discardableResult
    static func addTodo(
        title: String,
        notes: String? = nil,
        dueAt: Date? = nil,
        parent: Todo? = nil,
        project: Project? = nil,
        customer: Customer? = nil,
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
        if parent == nil { todo.customer = project?.customer ?? customer }
        try? context.save()
        return todo
    }

    /// Sets a top-level todo's customer and project together, so they never disagree:
    /// a project with a customer decides the customer, and choosing another customer
    /// drops a project that belongs to someone else.
    static func setTodoCustomer(_ todo: Todo, _ customer: Customer?, context: ModelContext) {
        guard todo.parent == nil else { return }
        if let owner = todo.relatedProject?.customer, owner.id != customer?.id { todo.relatedProject = nil }
        todo.customer = customer
        try? context.save()
    }

    static func setTodoProject(_ todo: Todo, _ project: Project?, context: ModelContext) {
        todo.relatedProject = project
        if todo.parent == nil, let owner = project?.customer { todo.customer = owner }
        try? context.save()
    }

    /// Moves a todo under `newParent` (nil: to the top level), at the end of its new
    /// siblings. False, and nothing changes, when `newParent` is the todo itself or
    /// one of its subtasks, which would make a cycle.
    @discardableResult
    static func moveTodo(_ todo: Todo, under newParent: Todo?, context: ModelContext) -> Bool {
        if let newParent, todo.contains(newParent) { return false }
        guard newParent?.id != todo.parent?.id else { return true }
        let siblings = newParent?.subtasks
            ?? ((try? context.fetch(FetchDescriptor<Todo>())) ?? []).filter { $0.parent == nil }
        todo.sortOrder = (siblings.filter { $0.id != todo.id }.map(\.sortOrder).max() ?? -1) + 1
        if newParent != nil {
            // A subtask works for its root's customer.
            todo.customer = nil
        } else if todo.customer == nil {
            // Back at the top level it keeps the customer it worked for until now.
            todo.customer = todo.effectiveCustomer
        }
        todo.parent = newParent
        try? context.save()
        return true
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

    /// The customer list is closed: nil, and nothing added, for an empty name or one
    /// another customer already goes by (`customerConflict`).
    @discardableResult
    static func addCustomer(name: String, defaultBillable: Bool = true, context: ModelContext) -> Customer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, customerConflict(name: trimmed, context: context) == nil else { return nil }
        let customer = Customer(name: trimmed, defaultBillable: defaultBillable)
        context.insert(customer)
        try? context.save()
        return customer
    }

    /// The first of `name` and `aliases` another customer than `excluded` already
    /// goes by: "Inditex", "inditex" and an existing alias "ITX" are the same customer.
    static func customerConflict(
        name: String? = nil,
        aliases: String? = nil,
        excluding excluded: Customer? = nil,
        context: ModelContext
    ) -> CustomerMatcher.Conflict? {
        let customers = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
        return CustomerMatcher.conflict(name: name, aliases: aliases, excluding: excluded, in: customers)
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
