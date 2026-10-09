import Foundation
import SwiftData

/// Tools that create or edit. None deletes.
extension MCPTools {

    func writeTools() -> [Tool] {
        let entryFields: [String: JSONObject] = [
            "title": Self.string("What the time was spent on."),
            "notes": Self.string("Free-form notes. " + Self.clearHint),
            "project": Self.string("Project id or name. " + Self.clearHint),
            "customer": Self.string("Customer id or name; defaults to the project's customer. " + Self.clearHint),
            "role": Self.string("Role id or name. " + Self.clearHint),
            "todo": Self.string("Todo id or title the time counts towards. " + Self.clearHint),
        ]
        return [
            Tool(
                name: "start_timer", title: "Start timer",
                description: "Starts the timer now on a new entry. A timer already running is stopped first.",
                properties: entryFields.filter { $0.key != "notes" },
                required: ["title"], readOnly: false
            ) { [unowned self] args in try startTimer(args) },

            Tool(
                name: "stop_timer", title: "Stop timer",
                description: "Stops the running timer, now or at an earlier time.",
                properties: ["at": Self.string("When it stopped, if not now. " + Self.dateHint)],
                required: [], readOnly: false
            ) { [unowned self] args in try stopTimer(args) },

            Tool(
                name: "create_entry", title: "Create entry",
                description: "Adds a finished time entry, e.g. time the user forgot to track. Refused if it overlaps another entry.",
                properties: entryFields.merging([
                    "start": Self.string("Start. " + Self.dateHint),
                    "end": Self.string("End, not in the future. " + Self.dateHint),
                ]) { a, _ in a },
                required: ["title", "start", "end"], readOnly: false
            ) { [unowned self] args in try createEntry(args) },

            Tool(
                name: "update_entry", title: "Update entry",
                description: "Changes an entry's fields. Only the fields given change. Use stop_timer to end a running entry.",
                properties: entryFields.merging([
                    "id": Self.string("The entry id."),
                    "start": Self.string("New start. " + Self.dateHint),
                    "end": Self.string("New end (finished entries only). " + Self.dateHint),
                ]) { a, _ in a },
                required: ["id"], readOnly: false
            ) { [unowned self] args in try updateEntry(args) },

            Tool(
                name: "create_todo", title: "Create todo",
                description: "Adds a todo, or a subtask when parent is given.",
                properties: [
                    "title": Self.string("The todo."),
                    "notes": Self.string("Details."),
                    "due": Self.string("Due date. " + Self.dateHint),
                    "parent": Self.string("Parent todo id or title, to add a subtask."),
                    "project": Self.string("Related project id or name."),
                ],
                required: ["title"], readOnly: false
            ) { [unowned self] args in try createTodo(args) },

            Tool(
                name: "update_todo", title: "Update todo",
                description: "Edits, completes, reopens or moves a todo. Only the fields given change.",
                properties: [
                    "todo": Self.string("The todo's id or title."),
                    "title": Self.string("New title."),
                    "notes": Self.string("Details. " + Self.clearHint),
                    "due": Self.string("Due date. " + Self.dateHint + " " + Self.clearHint),
                    "project": Self.string("Related project id or name. " + Self.clearHint),
                    "parent": Self.string("Move under this todo (id or title). Empty string moves it to the top level."),
                    "completed": Self.boolean("true to complete it, false to reopen it."),
                ],
                required: ["todo"], readOnly: false
            ) { [unowned self] args in try updateTodo(args) },

            Tool(
                name: "create_project", title: "Create project",
                description: "Adds a project.",
                properties: [
                    "name": Self.string("Project name."),
                    "customer": Self.string("Customer id or name."),
                    "default_billable": Self.boolean("Whether its time is billable (default true)."),
                    "details": Self.string("What the project is about; helps Hansel classify time."),
                ],
                required: ["name"], readOnly: false
            ) { [unowned self] args in try createProject(args) },

            Tool(
                name: "update_project", title: "Update project",
                description: "Renames a project or changes its customer, billable default or details.",
                properties: [
                    "project": Self.string("The project's id or name."),
                    "name": Self.string("New name."),
                    "customer": Self.string("Customer id or name. " + Self.clearHint),
                    "default_billable": Self.boolean("Whether its time is billable."),
                    "details": Self.string("What the project is about."),
                ],
                required: ["project"], readOnly: false
            ) { [unowned self] args in try updateProject(args) },

            Tool(
                name: "create_customer", title: "Create customer",
                description: "Adds a customer.",
                properties: [
                    "name": Self.string("Customer name."),
                    "default_billable": Self.boolean("Whether their time is billable (default true)."),
                    "email_domains": Self.string("Comma-separated email domains, to recognise their meetings."),
                ],
                required: ["name"], readOnly: false
            ) { [unowned self] args in try createCustomer(args) },

            Tool(
                name: "update_customer", title: "Update customer",
                description: "Renames a customer or changes its billable default or email domains.",
                properties: [
                    "customer": Self.string("The customer's id or name."),
                    "name": Self.string("New name."),
                    "default_billable": Self.boolean("Whether their time is billable."),
                    "email_domains": Self.string("Comma-separated email domains."),
                ],
                required: ["customer"], readOnly: false
            ) { [unowned self] args in try updateCustomer(args) },

            Tool(
                name: "create_role", title: "Create role",
                description: "Adds a role.",
                properties: [
                    "name": Self.string("Role name."),
                    "default_billable": Self.boolean("Whether time in this role is billable (default true)."),
                ],
                required: ["name"], readOnly: false
            ) { [unowned self] args in try createRole(args) },

            Tool(
                name: "update_role", title: "Update role",
                description: "Renames a role or changes its billable default.",
                properties: [
                    "role": Self.string("The role's id or name."),
                    "name": Self.string("New name."),
                    "default_billable": Self.boolean("Whether time in this role is billable."),
                ],
                required: ["role"], readOnly: false
            ) { [unowned self] args in try updateRole(args) },

            Tool(
                name: "rename_meeting", title: "Rename meeting",
                description: "Renames a meeting in Hansel (and in Meeting Notes when that is enabled).",
                properties: [
                    "id": Self.string("The meeting id."),
                    "title": Self.string("The new name."),
                ],
                required: ["id", "title"], readOnly: false
            ) { [unowned self] args in
                let record = try meeting(id: try args.requiredString("id"))
                MeetingTitleSync.rename(record, to: try args.requiredString("title"), context: context)
                return json(record)
            },

            Tool(
                name: "accept_todo_proposal", title: "Accept todo proposal",
                description: "Turns a pending proposal from a meeting into a todo, optionally adjusting it first.",
                properties: [
                    "id": Self.string("The proposal id."),
                    "title": Self.string("Todo title, if different."),
                    "due": Self.string("Due date. " + Self.dateHint + " " + Self.clearHint),
                    "project": Self.string("Project id or name. " + Self.clearHint),
                ],
                required: ["id"], readOnly: false
            ) { [unowned self] args in try acceptProposal(args) },

            Tool(
                name: "decline_todo_proposal", title: "Decline todo proposal",
                description: "Declines a pending proposal from a meeting. It stays listed as declined.",
                properties: ["id": Self.string("The proposal id.")],
                required: ["id"], readOnly: false
            ) { [unowned self] args in
                let proposal = try pendingProposal(try args.requiredString("id"))
                proposals.decline(proposal)
                return json(proposal)
            },
        ]
    }

    // MARK: - Timer and entries

    private func startTimer(_ args: MCPArguments) throws -> JSONObject {
        let title = try args.requiredString("title")
        let project = try optional(args, "project", self.project)
        let customer = try optional(args, "customer", self.customer) ?? project?.customer
        let role = try optional(args, "role", self.role)
        let todo = try optional(args, "todo", self.todo)
        let previous = controller.runningEntry
        controller.startManual(title: title, role: role, project: project, customer: customer, todo: todo)
        guard let entry = controller.runningEntry else { throw ToolError("The timer did not start.") }
        var result = json(entry)
        if let previous { result["stopped_previous"] = json(previous) }
        return result
    }

    private func stopTimer(_ args: MCPArguments, now: Date = Date()) throws -> JSONObject {
        guard let running = controller.runningEntry else { throw ToolError("No timer is running.") }
        let at = try args.date("at") ?? now
        guard at >= running.startAt else {
            throw ToolError("It started at \(Self.format(running.startAt)); it cannot stop before that.")
        }
        guard at <= now.addingTimeInterval(60) else { throw ToolError("at cannot be in the future.") }
        guard let stopped = controller.stop(at: at) else { throw ToolError("The timer did not stop.") }
        return json(stopped)
    }

    private func createEntry(_ args: MCPArguments, now: Date = Date()) throws -> JSONObject {
        let title = try args.requiredString("title")
        guard let start = try args.date("start"), let end = try args.date("end") else {
            throw ToolError("start and end are required.")
        }
        try checkTimes(start: start, end: end, now: now)
        try checkNoOverlap(start: start, end: end)
        let project = try optional(args, "project", self.project)
        let customer = try optional(args, "customer", self.customer) ?? project?.customer
        let role = try optional(args, "role", self.role)
        let todo = try optional(args, "todo", self.todo)
        let notes = try args.string("notes")
        let entry = TimeEntry(isConfirmed: true, source: .manual)
        HanselActions.saveEntry(entry, insert: true, context: context, controller: controller) { e in
            e.title = title
            e.startAt = start
            e.endAt = end
            e.notes = notes.flatMap { $0.isEmpty ? nil : $0 }
            e.project = project
            e.customer = customer
            e.role = role
            e.linkedTodo = todo
        }
        return json(entry)
    }

    private func updateEntry(_ args: MCPArguments, now: Date = Date()) throws -> JSONObject {
        let entry = try entry(id: try args.requiredString("id"))
        let isRunning = entry.endAt == nil
        if isRunning, args.has("end") {
            throw ToolError("This entry is running. Use stop_timer to end it.")
        }
        let start = try args.date("start") ?? entry.startAt
        let end = try args.date("end") ?? entry.endAt
        if let end {
            try checkTimes(start: start, end: end, now: now)
        } else if start > now {
            throw ToolError("A running entry cannot start in the future.")
        }
        if start != entry.startAt || end != entry.endAt {
            try checkNoOverlap(start: start, end: end ?? now, excluding: entry.id)
        }
        let title = try args.string("title")
        if title?.isEmpty == true { throw ToolError("title cannot be empty.") }
        let notes = try args.string("notes")
        let project = try change(args, "project", self.project)
        let customer = try change(args, "customer", self.customer)
        let role = try change(args, "role", self.role)
        let todo = try change(args, "todo", self.todo)

        HanselActions.saveEntry(entry, insert: false, context: context, controller: controller) { e in
            if let title { e.title = title }
            e.startAt = start
            if !isRunning { e.endAt = end }
            if let notes { e.notes = notes.isEmpty ? nil : notes }
            if let project {
                e.project = project.value
                // As in the app: a project brings its customer when none is set.
                if customer == nil, e.customer == nil { e.customer = project.value?.customer }
            }
            if let customer { e.customer = customer.value }
            if let role { e.role = role.value }
            if let todo { e.linkedTodo = todo.value }
        }
        return json(entry)
    }

    private func checkTimes(start: Date, end: Date, now: Date) throws {
        guard end > start else { throw ToolError("end must be after start.") }
        guard end <= now.addingTimeInterval(60) else {
            throw ToolError("end cannot be in the future. Use start_timer for time starting now.")
        }
    }

    // MARK: - Todos

    private func createTodo(_ args: MCPArguments) throws -> JSONObject {
        let title = try args.requiredString("title")
        let parent = try optional(args, "parent", self.todo)
        let project = try optional(args, "project", self.project)
        let notes = try args.string("notes").flatMap { $0.isEmpty ? nil : $0 }
        guard let todo = HanselActions.addTodo(
            title: title, notes: notes, dueAt: try args.date("due"), parent: parent, project: project, context: context
        ) else { throw ToolError("title is required.") }
        return json(todo)
    }

    private func updateTodo(_ args: MCPArguments) throws -> JSONObject {
        let todo = try self.todo(try args.requiredString("todo"))
        let title = try args.string("title")
        if title?.isEmpty == true { throw ToolError("title cannot be empty.") }
        let notes = try args.string("notes")
        let due: Date?? = args.has("due") ? .some(try args.date("due")) : .none
        let project = try change(args, "project", self.project)
        let parent = try change(args, "parent", self.todo)
        if let newParent = parent?.value, todo.contains(newParent) {
            throw ToolError("A todo cannot move under itself or one of its subtasks.")
        }
        let completed = try args.bool("completed")

        if let title { todo.title = title }
        if let notes { todo.notes = notes.isEmpty ? nil : notes }
        if let due { todo.dueAt = due }
        if let project { todo.relatedProject = project.value }
        if let parent, parent.value?.id != todo.parent?.id {
            let siblings = parent.value?.subtasks ?? fetchAll(Todo.self).filter { $0.parent == nil }
            todo.sortOrder = (siblings.filter { $0.id != todo.id }.map(\.sortOrder).max() ?? -1) + 1
            todo.parent = parent.value
        }
        if let completed, completed != todo.isCompleted {
            HanselActions.setCompleted(todo, completed, context: context)
        } else {
            try? context.save()
        }
        return json(todo)
    }

    // MARK: - Catalog

    private func createProject(_ args: MCPArguments) throws -> JSONObject {
        let name = try args.requiredString("name")
        try checkUnique(name, among: fetchAll(Project.self).map(\.name), kind: "project")
        let customer = try optional(args, "customer", self.customer)
        guard let project = HanselActions.addProject(
            name: name, customer: customer, defaultBillable: try args.bool("default_billable") ?? true, context: context
        ) else { throw ToolError("name is required.") }
        if let details = try args.string("details") {
            project.details = details
            try? context.save()
        }
        return json(project)
    }

    private func updateProject(_ args: MCPArguments) throws -> JSONObject {
        let project = try self.project(try args.requiredString("project"))
        if let name = try args.string("name") {
            guard !name.isEmpty else { throw ToolError("name cannot be empty.") }
            try checkUnique(name, among: fetchAll(Project.self).filter { $0.id != project.id }.map(\.name), kind: "project")
            project.name = name
        }
        if let customer = try change(args, "customer", self.customer) { project.customer = customer.value }
        if let details = try args.string("details") { project.details = details }
        try? context.save()
        if let billable = try args.bool("default_billable"), billable != project.defaultBillable {
            project.defaultBillable = billable
            let id = project.id
            HanselActions.refreshBillable(context: context) { $0.project?.id == id }
        }
        return json(project)
    }

    private func createCustomer(_ args: MCPArguments) throws -> JSONObject {
        let name = try args.requiredString("name")
        try checkUnique(name, among: fetchAll(Customer.self).map(\.name), kind: "customer")
        guard let customer = HanselActions.addCustomer(
            name: name, defaultBillable: try args.bool("default_billable") ?? true, context: context
        ) else { throw ToolError("name is required.") }
        if let domains = try args.string("email_domains") {
            customer.emailDomains = domains
            try? context.save()
        }
        return json(customer)
    }

    private func updateCustomer(_ args: MCPArguments) throws -> JSONObject {
        let customer = try self.customer(try args.requiredString("customer"))
        if let name = try args.string("name") {
            guard !name.isEmpty else { throw ToolError("name cannot be empty.") }
            try checkUnique(name, among: fetchAll(Customer.self).filter { $0.id != customer.id }.map(\.name), kind: "customer")
            customer.name = name
        }
        if let domains = try args.string("email_domains") { customer.emailDomains = domains }
        try? context.save()
        if let billable = try args.bool("default_billable"), billable != customer.defaultBillable {
            customer.defaultBillable = billable
            let id = customer.id
            HanselActions.refreshBillable(context: context) { $0.customer?.id == id }
        }
        return json(customer)
    }

    private func createRole(_ args: MCPArguments) throws -> JSONObject {
        let name = try args.requiredString("name")
        try checkUnique(name, among: fetchAll(Role.self).map(\.name), kind: "role")
        guard let role = HanselActions.addRole(
            name: name, defaultBillable: try args.bool("default_billable") ?? true, context: context
        ) else { throw ToolError("name is required.") }
        return json(role)
    }

    private func updateRole(_ args: MCPArguments) throws -> JSONObject {
        let role = try self.role(try args.requiredString("role"))
        if let name = try args.string("name") {
            guard !name.isEmpty else { throw ToolError("name cannot be empty.") }
            try checkUnique(name, among: fetchAll(Role.self).filter { $0.id != role.id }.map(\.name), kind: "role")
            role.name = name
        }
        try? context.save()
        if let billable = try args.bool("default_billable"), billable != role.defaultBillable {
            role.defaultBillable = billable
            let id = role.id
            HanselActions.refreshBillable(context: context) { $0.role?.id == id }
        }
        return json(role)
    }

    private func checkUnique(_ name: String, among names: [String], kind: String) throws {
        if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolError("A \(kind) named \"\(name)\" already exists.")
        }
    }

    // MARK: - Proposals

    private func pendingProposal(_ id: String) throws -> TodoProposal {
        let proposal = try proposal(id: id)
        guard proposal.status == .pending else {
            throw ToolError("That proposal was already \(proposal.status.rawValue).")
        }
        return proposal
    }

    private func acceptProposal(_ args: MCPArguments) throws -> JSONObject {
        let proposal = try pendingProposal(try args.requiredString("id"))
        if let title = try args.string("title"), !title.isEmpty { proposal.title = title }
        if args.has("due") { proposal.dueAt = try args.date("due") }
        if let project = try change(args, "project", self.project) { proposal.projectID = project.value?.id }
        let todo = proposals.accept(proposal)
        return ["proposal": json(proposal), "todo": json(todo)]
    }

    // MARK: - Optional references

    /// A reference to set on something new: nil when absent or empty.
    private func optional<T>(_ args: MCPArguments, _ key: String, _ find: (String) throws -> T) throws -> T? {
        guard let reference = try args.reference(key), !reference.isEmpty else { return nil }
        return try find(reference)
    }

    /// A reference to change on something existing: nil leaves it, an empty string
    /// clears it, anything else must resolve.
    private func change<T>(_ args: MCPArguments, _ key: String, _ find: (String) throws -> T) throws -> Change<T>? {
        guard let reference = try args.reference(key) else { return nil }
        return Change(value: reference.isEmpty ? nil : try find(reference))
    }

    struct Change<T> {
        let value: T?
    }
}
