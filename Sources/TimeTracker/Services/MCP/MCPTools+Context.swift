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
