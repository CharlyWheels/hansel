import Foundation
import SwiftData

/// Tools for the assistant that collects context from Slack, email, Teams, the calendar
/// and Confluence: what to look for and since when, a place to send what it found, and
/// a way to read the items back. Hansel checks every suggestion against its own lists.
extension MCPTools {

    func contextTools() -> [Tool] {
        let sources = ContextItem.Source.allCases.filter { $0 != .meeting }.map(\.rawValue)
        let itemSchema: JSONObject = [
            "type": "object",
            "properties": [
                "source": Self.choice(sources, "Where it comes from."),
                "external_id": Self.string("Stable id in that source (thread ts, conversation id, page id, event id). The same id updates the item."),
                "url": Self.string("Link to the original."),
                "title": Self.string("Short title: thread topic, email subject, page or event title."),
                "date": Self.string("When it happened (the latest message). " + Self.dateHint),
                "participants": ["type": "array", "items": ["type": "string"],
                                 "description": "Email addresses where known, else names or @handles."],
                "channel": Self.string("Slack or Teams channel name, without #, when it was in one."),
                "summary": Self.string("One or two lines: what it is about and where it stands. Max 500 characters."),
                "details": Self.string("The facts worth keeping: decisions, numbers, dates, commitments, open questions, who owns what. Max 2000 characters. No small talk."),
                "todo_id": Self.string("Id of the open todo it belongs to, from get_ingest_brief, if any."),
                "customer": Self.string("Customer name or id from get_ingest_brief, or the name of a customer missing from the list."),
                "confidence": ["type": "number", "description": "0 to 1: how sure you are of todo_id / customer."],
                "reason": Self.string("Why you chose that todo or customer, in a few words."),
            ],
            "required": ["source", "external_id", "title", "date", "summary"],
        ]
        return [
            Tool(
                name: "get_ingest_brief", title: "Get context collection brief",
                description: """
                Start of every context collection. Returns, per source, the time to collect from; the user's \
                own emails and names; the customers with their aliases (domains, acronyms, Slack channels, \
                contacts); the open todos to assign things to; and the user's latest corrections, to follow. \
                Then read each source from that time, and send what you find with add_context_items.
                """,
                properties: [:], required: [], readOnly: true
            ) { [unowned self] _ in ingestBrief() },

            Tool(
                name: "add_context_items", title: "Add context items",
                description: """
                Sends what was collected: one item per Slack thread, email conversation, Teams chat, calendar \
                event or Confluence page about the user's work. Hansel assigns each to a todo or customer, \
                checking your todo_id / customer against the customers' aliases; what it cannot place goes to \
                the user's inbox. Sending the same source and external_id again updates the item. Skip \
                personal matters, newsletters, notifications and automated mail. After finishing a source, \
                pass it in completed_sources so the next collection starts there. Up to 50 items per call.
                """,
                properties: [
                    "items": ["type": "array", "items": itemSchema, "description": "The items, up to 50."],
                    "completed_sources": [
                        "type": "object",
                        "description": "Sources fully read in this run, each with the time it was read up to, e.g. {\"slack\": \"2026-10-16T18:00\"}.",
                        "additionalProperties": ["type": "string"],
                    ],
                ],
                required: [], readOnly: false
            ) { [unowned self] args in try addContextItems(args) },

            Tool(
                name: "list_context_items", title: "List context items",
                description: "Context items (meetings, messages, emails, pages), newest first, with what they are assigned to.",
                properties: [
                    "status": Self.choice(ContextItem.Status.allCases.map(\.rawValue), "Only this status."),
                    "todo": Self.string("Only items of this todo (id or title), its subtasks included."),
                    "customer": Self.string("Only items of this customer (id or name)."),
                    "limit": Self.integer("At most this many (default 50)."),
                ],
                required: [], readOnly: true
            ) { [unowned self] args in try listContextItems(args) },
        ]
    }

    // MARK: - Brief

    private func ingestBrief(now: Date = Date()) -> JSONObject {
        let customers = fetchAll(Customer.self).sorted { $0.name < $1.name }
        let todos = fetchAll(Todo.self).filter { !$0.isCompleted && !$0.isExcludedFromContext }
            .sorted { $0.breadcrumbPath < $1.breadcrumbPath }
        var since: JSONObject = [:]
        for source in ContextItem.Source.allCases where source != .meeting {
            since[source.rawValue] = Self.format(contextItems.since(source, now: now))
        }
        return [
            "now": Self.format(now),
            "collect_since": since,
            "me": [
                "emails": ContextService.userEmails(),
                "names": OwnerMatcher.userNames(),
            ],
            "customers": customers.filter { !$0.excludedFromContext }.map { customer -> JSONObject in
                [
                    "id": customer.id.uuidString,
                    "name": customer.name,
                    "aliases": CustomerMatcher.aliases(of: customer).map { alias -> JSONObject in
                        ["kind": alias.kind.rawValue,
                         "value": alias.isAcronym ? alias.value.uppercased() : alias.value,
                         "acronym": alias.isAcronym]
                    },
                    "projects": customer.projects.map(\.name).sorted(),
                ]
            },
            "skip_customers": customers.filter(\.excludedFromContext).map { customer -> JSONObject in
                ["name": customer.name, "aliases": CustomerMatcher.aliases(of: customer).map(\.value)]
            },
            "open_todos": todos.map { todo -> JSONObject in
                [
                    "id": todo.id.uuidString,
                    "path": todo.breadcrumbPath,
                    "customer": Self.value(todo.effectiveCustomer?.name),
                    "project": Self.value(todo.inheritedProject?.name),
                    "notes": Self.value(todo.notes.map { ContextService.clip($0, 200) }),
                ]
            },
            "your_past_corrections": contextItems.recentDecisions().map { item -> JSONObject in
                [
                    "source": item.source.rawValue,
                    "title": item.title,
                    "channel": Self.value(item.channel),
                    "participants": Array(item.participants.prefix(6)),
                    "decision": decisionText(item),
                ]
            },
            "rules": [
                "Acronyms (acronym: true) only count written in capitals; other names in any case, as whole words.",
                "Assign to the most specific open todo that fits; give a customer alone when no todo fits.",
                "Below \(ContextClassifier.assistantThreshold) confidence, Hansel sends the item to the user's inbox unless its own signals agree.",
                "Never send anything about skip_customers or personal matters.",
            ],
        ]
    }

    private func decisionText(_ item: ContextItem) -> String {
        switch item.status {
        case .discarded: return "discarded (not worth keeping)"
        case .unassigned: return "left unassigned"
        case .assigned:
            if let todoID = item.todoID, let todo = fetchAll(Todo.self).first(where: { $0.id == todoID }) {
                return "todo: \(todo.breadcrumbPath)"
            }
            let customer = item.customerID.flatMap { id in fetchAll(Customer.self).first { $0.id == id } }
            return "customer only: \(customer?.name ?? "?")"
        }
    }

    // MARK: - Adding

    static let maxItemsPerCall = 50

    private func addContextItems(_ args: MCPArguments, now: Date = Date()) throws -> JSONObject {
        let rawItems = try args.objects("items") ?? []
        guard rawItems.count <= Self.maxItemsPerCall else {
            throw ToolError("At most \(Self.maxItemsPerCall) items per call; send the rest in another call.")
        }
        var incoming: [ContextService.Incoming] = []
        for (index, raw) in rawItems.enumerated() {
            do {
                incoming.append(try Self.incoming(MCPArguments(raw)))
            } catch let error as ToolError {
                throw ToolError("items[\(index)]: \(error.message)")
            }
        }
        // Sources are validated before anything is saved, so a bad call changes nothing.
        var completed: [(ContextItem.Source, Date)] = []
        for (key, value) in try args.object("completed_sources") ?? [:] {
            guard let source = ContextItem.Source(rawValue: key), source != .meeting else {
                throw ToolError("completed_sources: unknown source \"\(key)\".")
            }
            guard let text = value as? String, let date = MCPArguments.parseDate(text) else {
                throw ToolError("completed_sources.\(key) must be a date. Use \(Self.dateHint)")
            }
            completed.append((source, date))
        }

        let outcomes = contextItems.ingest(incoming, now: now)
        for (source, date) in completed { contextItems.markCollected(source, through: date, now: now) }

        let counts = Dictionary(grouping: outcomes, by: \.status).mapValues(\.count)
        return [
            "assigned": counts["assigned"] ?? 0,
            "unassigned": counts["unassigned"] ?? 0,
            "skipped": counts["skipped"] ?? 0,
            "items": outcomes.map { outcome -> JSONObject in
                [
                    "external_id": outcome.externalID,
                    "status": outcome.status,
                    "todo": Self.ref(outcome.todo?.id, outcome.todo?.breadcrumbPath),
                    "customer": Self.ref(outcome.customer?.id, outcome.customer?.name),
                    "reason": outcome.reason,
                ]
            },
            "collect_since": Dictionary(uniqueKeysWithValues: completed.map {
                ($0.0.rawValue, Self.format(contextItems.since($0.0, now: now)))
            }),
        ]
    }

    private static func incoming(_ args: MCPArguments) throws -> ContextService.Incoming {
        let sourceName = try args.requiredString("source")
        guard let source = ContextItem.Source(rawValue: sourceName), source != .meeting else {
            throw ToolError("source \"\(sourceName)\" is not one of slack, email, teams, calendar, confluence, github, other.")
        }
        guard let date = try args.date("date") else { throw ToolError("date is required.") }
        let todoID: UUID?
        if let text = try args.string("todo_id"), !text.isEmpty {
            guard let id = UUID(uuidString: text) else { throw ToolError("todo_id must be a todo id from get_ingest_brief.") }
            todoID = id
        } else {
            todoID = nil
        }
        let confidence = try args.number("confidence")
        if let confidence, !(0...1).contains(confidence) { throw ToolError("confidence must be between 0 and 1.") }
        return ContextService.Incoming(
            source: source,
            externalID: try args.requiredString("external_id"),
            url: try args.string("url"),
            title: try args.requiredString("title"),
            occurredAt: date,
            participants: try args.strings("participants") ?? [],
            channel: try args.string("channel").flatMap { $0.isEmpty ? nil : $0 },
            summary: try args.requiredString("summary"),
            details: try args.string("details") ?? "",
            suggestedTodoID: todoID,
            suggestedCustomer: try args.string("customer").flatMap { $0.isEmpty ? nil : $0 },
            confidence: confidence,
            reason: try args.string("reason")
        )
    }

    // MARK: - Reading

    private func listContextItems(_ args: MCPArguments) throws -> [JSONObject] {
        var items = fetchAll(ContextItem.self).sorted { $0.occurredAt > $1.occurredAt }
        if let status = try args.string("status"), !status.isEmpty {
            guard ContextItem.Status(rawValue: status) != nil else { throw ToolError("Unknown status \"\(status)\".") }
            items = items.filter { $0.statusRaw == status }
        }
        if let reference = try args.reference("todo"), !reference.isEmpty {
            let root = try todo(reference)
            let ids = Set(Self.subtree(root).map(\.id))
            items = items.filter { $0.todoID.map(ids.contains) ?? false }
        }
        if let reference = try args.reference("customer"), !reference.isEmpty {
            let id = try customer(reference).id
            items = items.filter { $0.customerID == id }
        }
        let todos = fetchAll(Todo.self)
        let customers = fetchAll(Customer.self)
        // Never hand out what belongs to a customer kept out of AI context.
        let hidden = Set(customers.filter(\.excludedFromContext).map(\.id))
        items = items.filter { !($0.customerID.map(hidden.contains) ?? false) }
        return items.prefix(max(1, try args.int("limit") ?? 50)).map { item in
            let todo = item.todoID.flatMap { id in todos.first { $0.id == id } }
            let customer = item.customerID.flatMap { id in customers.first { $0.id == id } }
            return [
                "id": item.id.uuidString,
                "source": item.source.rawValue,
                "external_id": item.externalID,
                "url": Self.value(item.url),
                "title": item.title,
                "date": Self.format(item.occurredAt),
                "participants": item.participants,
                "channel": Self.value(item.channel),
                "summary": item.summary,
                "details": item.details,
                "status": item.status.rawValue,
                "todo": Self.ref(todo?.id, todo?.breadcrumbPath),
                "customer": Self.ref(customer?.id, customer?.name),
                "confidence": item.confidence,
                "assigned_by": item.assignedBy.rawValue,
                "reason": item.reason,
            ]
        }
    }

    static func subtree(_ todo: Todo) -> [Todo] {
        [todo] + todo.subtasks.flatMap(subtree)
    }
}

// MARK: - Dossiers

extension MCPTools {

    func dossierTools() -> [Tool] {
        [
            Tool(
                name: "get_dossier_work", title: "Get dossiers to update",
                description: """
                Dossiers that have new context since they were last written: todos first (a todo's covers \
                its subtasks), then customers (written from their todos' dossiers and the items about the \
                customer alone). Each comes with its current dossier and only the new items. Rewrite each \
                with update_dossier, passing its `through` back; call again until nothing is left.
                """,
                properties: ["limit": Self.integer("At most this many (default 10).")],
                required: [], readOnly: true
            ) { [unowned self] args in try dossierWork(args) },

            Tool(
                name: "update_dossier", title: "Update dossier",
                description: """
                Saves the rewritten dossier of a todo or customer: the current one with the new items worked \
                in, in Markdown with exactly these sections, in this order:

                \(DossierService.template)

                Keep facts, dates, numbers, names and links; drop chit-chat. At most \
                \(DossierService.todoLimit) characters for a todo and \(DossierService.customerLimit) for a \
                customer: condense old detail rather than dropping recent facts, and always keep the link to \
                a key source. Anything the user wrote in the current dossier stays unless newer facts \
                contradict it. Refused, with the reason, when a section is missing or it is too long.
                """,
                properties: [
                    "kind": Self.choice(["todo", "customer"], "What the dossier is about."),
                    "id": Self.string("The todo's or customer's id, from get_dossier_work."),
                    "dossier": Self.string("The whole dossier, in Markdown."),
                    "through": Self.string("The `through` value get_dossier_work gave for it."),
                ],
                required: ["kind", "id", "dossier", "through"], readOnly: false
            ) { [unowned self] args in try updateDossier(args) },
        ]
    }

    /// `through` rounded up to the millisecond, so an item saved within the same
    /// millisecond is never counted as new again.
    static func throughToken(_ date: Date) -> String {
        let rounded = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate * 1000).rounded(.up) / 1000)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: rounded)
    }

    private func dossierWork(_ args: MCPArguments) throws -> [JSONObject] {
        let limit = max(1, min(try args.int("limit") ?? 10, 25))
        return DossierService.pendingWork(context: context, limit: limit).map { work in
            var json: JSONObject = [
                "kind": work.kind.rawValue,
                "id": work.id.uuidString,
                "name": work.name,
                "customer": Self.value(work.customerName),
                "current_dossier": work.current,
                "through": Self.throughToken(work.through),
                "new_items": work.newItems.map { item -> JSONObject in
                    [
                        "source": item.source.rawValue,
                        "title": item.title,
                        "date": Self.format(item.occurredAt),
                        "url": Self.value(item.url),
                        "participants": Array(item.participants.prefix(10)),
                        "summary": item.summary,
                        "details": item.details,
                    ]
                },
            ]
            if work.kind == .customer {
                json["todo_dossiers"] = work.todoDossiers.map { ["todo": $0.path, "dossier": $0.dossier] }
            }
            return json
        }
    }

    private func updateDossier(_ args: MCPArguments) throws -> JSONObject {
        let kind = try args.requiredString("kind")
        let id = try args.requiredString("id")
        let markdown = try args.requiredString("dossier")
        guard let through = try args.date("through") else { throw ToolError("through is required.") }
        do {
            switch kind {
            case "todo":
                let todo = try self.todo(id)
                try DossierService.saveTodo(todo, markdown: markdown, through: through, context: context)
                return ["saved": true, "todo": todo.breadcrumbPath, "characters": todo.dossier.count]
            case "customer":
                let customer = try self.customer(id)
                try DossierService.saveCustomer(customer, markdown: markdown, through: through, context: context)
                return ["saved": true, "customer": customer.name, "characters": customer.dossier.count]
            default:
                throw ToolError("kind must be todo or customer.")
            }
        } catch let rejection as DossierService.Rejection {
            throw ToolError(rejection.message)
        }
    }
}

// MARK: - Working on a todo

extension MCPTools {

    func taskContextTools() -> [Tool] {
        [
            Tool(
                name: "get_task_context", title: "Get task context",
                description: """
                Everything known about a todo, to start working on it. It returns the todo (notes, due date, \
                subtasks), its brief (goal, deliverable, done-when, constraints, plan) and the user's autonomy \
                policy, its dossier (and its top-level todo's, for a subtask), a summary of its customer's \
                dossier, the time logged on it, the newest context not yet in the dossier, and the links to \
                its sources. Call this first; read the original sources only for what is missing.
                """,
                properties: ["todo": Self.string("The todo's id or title.")],
                required: ["todo"], readOnly: true
            ) { [unowned self] args in try taskContext(args) },

            Tool(
                name: "update_task_brief", title: "Update task brief",
                description: """
                Saves a todo's brief: what an agent needs to do it without asking. When a todo has no brief, \
                draft one from get_task_context, ask the user at most three questions for what you cannot \
                infer, and save it. Tick plan steps ([x]) as they are done. Exactly these sections:

                \(TaskBrief.template)

                Mark each plan step (auto) when the autonomy policy lets you do it alone, (ask) when it needs \
                the user's OK.
                """,
                properties: [
                    "todo": Self.string("The todo's id or title."),
                    "brief": Self.string("The whole brief, in Markdown."),
                ],
                required: ["todo", "brief"], readOnly: false
            ) { [unowned self] args in try updateTaskBrief(args) },

            Tool(
                name: "get_autonomy_policy", title: "Get autonomy policy",
                description: "The user's rules for agents: what to do without asking, what to ask first, and what never to do. Follow it in every task.",
                properties: [:], required: [], readOnly: true
            ) { _ in ["policy": AutonomyPolicy.current] },

            Tool(
                name: "search_context", title: "Search context",
                description: """
                Finds meetings, Slack threads, emails, Teams chats, calendar events, Confluence pages and \
                GitHub items Hansel has collected, newest first. It returns short summaries with links, not \
                the original text; open a link when you need the details. All filters are optional and \
                combine.
                """,
                properties: [
                    "customer": Self.string("Customer id or name."),
                    "project": Self.string("Project id or name."),
                    "todo": Self.string("Todo id or title (its subtasks included)."),
                    "person": Self.string("Part of a participant's name or email address."),
                    "text": Self.string("Words to find in the title, summary or details."),
                    "source": Self.choice(ContextItem.Source.allCases.map(\.rawValue), "Only this source."),
                    "from": Self.string("From this date. " + Self.dateHint),
                    "to": Self.string("Up to this date. " + Self.dateHint),
                    "include_details": Self.boolean("Also return each item's kept facts (default false)."),
                    "limit": Self.integer("At most this many (default 20, max 100)."),
                ],
                required: [], readOnly: true
            ) { [unowned self] args in try searchContext(args) },
        ]
    }

    // MARK: get_task_context

    private func taskContext(_ args: MCPArguments, now: Date = Date()) throws -> JSONObject {
        let todo = try self.todo(try args.requiredString("todo"))
        guard !todo.isExcludedFromContext else {
            throw ToolError("This todo belongs to a customer kept out of AI context.")
        }
        let tree = Self.subtree(todo)
        let ids = Set(tree.map(\.id))
        let root = todo.root
        let customer = todo.effectiveCustomer

        // Linked to the todo or its subtasks, plus its project's time no todo claims.
        let entries = ContextInsights.entries(for: todo, in: fetchAll(TimeEntry.self))
        func seconds(_ list: [TimeEntry]) -> TimeInterval { ContextInsights.seconds(list, now: now) }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)

        let items = fetchAll(ContextItem.self)
            .filter { $0.status == .assigned && ($0.todoID.map(ids.contains) ?? false) }
            .sorted { $0.occurredAt > $1.occurredAt }
        let since = todo.dossierThrough ?? .distantPast
        let notInDossier = items.filter { $0.updatedAt > since }

        var result: JSONObject = [
            "todo": [
                "id": todo.id.uuidString,
                "path": todo.breadcrumbPath,
                "notes": Self.value(todo.notes),
                "due": Self.value(todo.dueAt),
                "completed": todo.isCompleted,
                "project": Self.ref(todo.inheritedProject?.id, todo.inheritedProject?.name),
                "customer": Self.ref(customer?.id, customer?.name),
            ] as JSONObject,
            "subtasks": tree.dropFirst().map { sub -> JSONObject in
                ["id": sub.id.uuidString, "path": sub.breadcrumbPath, "completed": sub.isCompleted,
                 "due": Self.value(sub.dueAt), "notes": Self.value(sub.notes)]
            },
            "brief": todo.brief.isEmpty ? NSNull() : todo.brief,
            "brief_progress": [
                "steps": TaskBrief.steps(in: todo.brief).count,
                "done": TaskBrief.steps(in: todo.brief).filter(\.done).count,
                "next": Self.value(TaskBrief.steps(in: todo.brief).first { !$0.done }?.text),
            ] as JSONObject,
            "autonomy_policy": AutonomyPolicy.current,
            "dossier": todo.dossier.isEmpty ? NSNull() : todo.dossier,
            "dossier_updated_at": Self.value(todo.dossierUpdatedAt),
            "time_logged": [
                "total_hours": Self.hours(seconds(entries)),
                "on_the_todo_hours": Self.hours(seconds(entries.filter { $0.linkedTodo != nil })),
                "on_its_project_only_hours": Self.hours(seconds(entries.filter { $0.linkedTodo == nil })),
                "last_7_days_hours": Self.hours(seconds(entries.filter { $0.startAt >= weekAgo })),
                "entries": entries.count,
                "first_worked": Self.value(entries.map(\.startAt).min()),
                "last_worked": Self.value(entries.map(\.startAt).max()),
            ] as JSONObject,
            "not_yet_in_dossier": notInDossier.prefix(20).map { item -> JSONObject in
                ["source": item.source.rawValue, "title": item.title, "date": Self.format(item.occurredAt),
                 "url": Self.value(item.url), "summary": item.summary, "details": item.details]
            },
            "sources": items.prefix(30).map { item -> JSONObject in
                ["source": item.source.rawValue, "title": item.title, "date": Self.format(item.occurredAt),
                 "url": Self.value(item.url), "summary": item.summary]
            },
        ]
        if root.id != todo.id, !root.dossier.isEmpty {
            result["top_level_todo"] = ["path": root.breadcrumbPath, "dossier": root.dossier] as JSONObject
        }
        if let customer, !customer.dossier.isEmpty {
            result["customer_dossier_summary"] = Self.sections(["## Summary", "## Status", "## People"],
                                                               of: customer.dossier)
        }
        return result
    }

    /// The named sections of a dossier, in its own order, headings included.
    static func sections(_ wanted: [String], of markdown: String) -> String {
        var kept: [String] = []
        var keeping = false
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { keeping = wanted.contains(trimmed) }
            if keeping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateTaskBrief(_ args: MCPArguments) throws -> JSONObject {
        let todo = try self.todo(try args.requiredString("todo"))
        do {
            try TaskBrief.save(todo, markdown: try args.requiredString("brief"), context: context)
        } catch let rejection as DossierService.Rejection {
            throw ToolError(rejection.message)
        }
        let steps = TaskBrief.steps(in: todo.brief)
        return ["saved": true, "todo": todo.breadcrumbPath, "steps": steps.count,
                "done": steps.filter(\.done).count, "need_approval": steps.filter { $0.needsApproval && !$0.done }.count]
    }

    // MARK: search_context

    private func searchContext(_ args: MCPArguments) throws -> [JSONObject] {
        let todos = fetchAll(Todo.self)
        let customers = fetchAll(Customer.self)
        let todoByID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let hidden = Set(customers.filter(\.excludedFromContext).map(\.id))

        var items = fetchAll(ContextItem.self).filter { item in
            item.status != .discarded
                && !(item.customerID.map(hidden.contains) ?? false)
                && !(item.todoID.flatMap { todoByID[$0] }?.isExcludedFromContext ?? false)
        }
        if let reference = try args.reference("customer"), !reference.isEmpty {
            let id = try customer(reference).id
            items = items.filter {
                $0.customerID == id || ($0.todoID.flatMap { todoByID[$0] }?.effectiveCustomer?.id == id)
            }
        }
        if let reference = try args.reference("project"), !reference.isEmpty {
            let id = try project(reference).id
            items = items.filter { $0.todoID.flatMap { todoByID[$0] }?.inheritedProject?.id == id }
        }
        if let reference = try args.reference("todo"), !reference.isEmpty {
            let ids = Set(Self.subtree(try todo(reference)).map(\.id))
            items = items.filter { $0.todoID.map(ids.contains) ?? false }
        }
        if let person = try args.string("person"), !person.isEmpty {
            let needle = Self.fold(person)
            items = items.filter { $0.participants.contains { Self.fold($0).contains(needle) } }
        }
        if let text = try args.string("text"), !text.isEmpty {
            let words = Self.fold(text).split(separator: " ").map(String.init)
            items = items.filter { item in
                let haystack = Self.fold(item.title + " " + item.summary + " " + item.details)
                return words.allSatisfy { haystack.contains($0) }
            }
        }
        if let sourceName = try args.string("source"), !sourceName.isEmpty {
            guard let source = ContextItem.Source(rawValue: sourceName) else {
                throw ToolError("Unknown source \"\(sourceName)\".")
            }
            items = items.filter { $0.source == source }
        }
        if let from = try args.date("from") { items = items.filter { $0.occurredAt >= from } }
        if let to = try args.date("to") {
            // A bare date means the whole of that day.
            let end = Calendar.current.dateComponents([.hour, .minute, .second], from: to) == DateComponents(hour: 0, minute: 0, second: 0)
                ? to.addingTimeInterval(86_400) : to
            items = items.filter { $0.occurredAt < end }
        }
        let withDetails = try args.bool("include_details") ?? false
        let limit = max(1, min(try args.int("limit") ?? 20, 100))
        return items.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit).map { item in
            let todo = item.todoID.flatMap { todoByID[$0] }
            let customer = item.customerID.flatMap { id in customers.first { $0.id == id } } ?? todo?.effectiveCustomer
            var json: JSONObject = [
                "source": item.source.rawValue,
                "title": item.title,
                "date": Self.format(item.occurredAt),
                "url": Self.value(item.url),
                "summary": item.summary,
                "participants": Array(item.participants.prefix(10)),
                "todo": Self.ref(todo?.id, todo?.breadcrumbPath),
                "customer": Self.ref(customer?.id, customer?.name),
                "status": item.status.rawValue,
            ]
            if withDetails { json["details"] = item.details }
            return json
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
