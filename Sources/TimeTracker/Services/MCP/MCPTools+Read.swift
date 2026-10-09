import Foundation
import SwiftData

/// Tools that only read.
extension MCPTools {

    func readTools() -> [Tool] {
        [
            Tool(
                name: "get_today", title: "Today",
                description: "Today's tracked time, billable share and entries, plus the running timer if any.",
                properties: [:], required: [], readOnly: true
            ) { [unowned self] _ in today() },

            Tool(
                name: "get_running_entry", title: "Running timer",
                description: "The entry the timer is running on now, or running: false.",
                properties: [:], required: [], readOnly: true
            ) { [unowned self] _ in
                guard let entry = controller.runningEntry else { return ["running": false] }
                return json(entry)
            },

            Tool(
                name: "list_entries", title: "List entries",
                description: "Time entries overlapping a range, newest first. Defaults to the last 7 days.",
                properties: [
                    "from": Self.string("Range start. " + Self.dateHint),
                    "to": Self.string("Range end (exclusive). Defaults to now. " + Self.dateHint),
                    "project": Self.string("Only this project (id or name)."),
                    "customer": Self.string("Only this customer (id or name)."),
                    "role": Self.string("Only this role (id or name)."),
                    "text": Self.string("Only entries whose title or notes contain this."),
                    "needs_review": Self.boolean("Only entries Hansel created that nobody confirmed yet."),
                    "limit": Self.integer("At most this many (default 50, max 500)."),
                ],
                required: [], readOnly: true
            ) { [unowned self] args in try listEntries(args) },

            Tool(
                name: "get_entry", title: "Get entry",
                description: "One time entry by id.",
                properties: ["id": Self.string("The entry id.")],
                required: ["id"], readOnly: true
            ) { [unowned self] args in json(try entry(id: try args.requiredString("id"))) },

            Tool(
                name: "list_projects", title: "List projects",
                description: "All projects with their customer and billable default.",
                properties: ["customer": Self.string("Only this customer's projects (id or name).")],
                required: [], readOnly: true
            ) { [unowned self] args in
                var projects = fetchAll(Project.self)
                if let ref = try args.string("customer"), !ref.isEmpty {
                    let id = try customer(ref).id
                    projects = projects.filter { $0.customer?.id == id }
                }
                return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map(json)
            },

            Tool(
                name: "list_customers", title: "List customers",
                description: "All customers with their projects and billable default.",
                properties: [:], required: [], readOnly: true
            ) { [unowned self] _ in
                fetchAll(Customer.self)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map(json)
            },

            Tool(
                name: "list_roles", title: "List roles",
                description: "All roles with their billable default.",
                properties: [:], required: [], readOnly: true
            ) { [unowned self] _ in
                fetchAll(Role.self)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map(json)
            },

            Tool(
                name: "list_todos", title: "List todos",
                description: "Todos in the order Hansel shows them, subtasks after their parent.",
                properties: [
                    "include_completed": Self.boolean("Also finished todos (default false)."),
                    "project": Self.string("Only todos for this project (id or name)."),
                ],
                required: [], readOnly: true
            ) { [unowned self] args in try listTodos(args) },

            Tool(
                name: "list_meetings", title: "List meetings",
                description: "Meetings recorded with Meeting Notes, newest first. Defaults to the last 14 days.",
                properties: [
                    "from": Self.string("Range start. " + Self.dateHint),
                    "to": Self.string("Range end. Defaults to now. " + Self.dateHint),
                    "text": Self.string("Only meetings whose title or participants contain this."),
                    "limit": Self.integer("At most this many (default 50, max 200)."),
                ],
                required: [], readOnly: true
            ) { [unowned self] args in try listMeetings(args) },

            Tool(
                name: "get_meeting", title: "Get meeting",
                description: "One meeting with its summary, participants, linked entry and proposed todos.",
                properties: ["id": Self.string("The meeting id.")],
                required: ["id"], readOnly: true
            ) { [unowned self] args in try getMeeting(args) },

            Tool(
                name: "list_todo_proposals", title: "List todo proposals",
                description: "Tasks Hansel heard in meetings, waiting to be accepted as todos or declined.",
                properties: [
                    "status": Self.choice(["pending", "accepted", "declined"], "Default pending."),
                    "meeting": Self.string("Only this meeting's proposals (meeting id)."),
                ],
                required: [], readOnly: true
            ) { [unowned self] args in
                let status = try args.string("status").flatMap { $0.isEmpty ? nil : $0 } ?? "pending"
                guard TodoProposal.Status(rawValue: status) != nil else {
                    throw ToolError("status must be pending, accepted or declined.")
                }
                let meetingID = try args.string("meeting").flatMap(UUID.init(uuidString:))
                return fetchAll(TodoProposal.self)
                    .filter { $0.statusRaw == status && (meetingID == nil || $0.meetingID == meetingID) }
                    .sorted { $0.meetingStartedAt > $1.meetingStartedAt }
                    .map(json)
            },

            Tool(
                name: "get_report", title: "Time report",
                description: "Tracked and billable hours for a period, broken down by customer, project and role.",
                properties: [
                    "period": Self.choice(
                        ["today", "this_week", "last_week", "this_month", "last_month", "custom"],
                        "Default this_week. custom needs from and to."
                    ),
                    "from": Self.string("Custom range start. " + Self.dateHint),
                    "to": Self.string("Custom range end (exclusive). " + Self.dateHint),
                ],
                required: [], readOnly: true
            ) { [unowned self] args in try report(args) },
        ]
    }

    // MARK: - Implementations

    private func today(now: Date = Date()) -> JSONObject {
        let summary = TodaySummary.load(context: context, now: now)
        let dayStart = Calendar.current.startOfDay(for: now)
        let entries = entries(overlapping: dayStart, now.addingTimeInterval(1), now: now)
        return [
            "date": Self.format(dayStart),
            "tracked_minutes": Self.minutes(summary.strip.trackedSeconds),
            "billable_percent": summary.billablePercent,
            "entry_count": summary.entryCount,
            "running": controller.runningEntry.map { json($0, now: now) } ?? NSNull(),
            "entries": entries.map { json($0, now: now) },
        ]
    }

    private func listEntries(_ args: MCPArguments, now: Date = Date()) throws -> [JSONObject] {
        let to = try args.date("to") ?? now
        let from = try args.date("from") ?? Calendar.current.date(byAdding: .day, value: -7, to: to) ?? to
        guard from < to else { throw ToolError("from must be before to.") }
        var entries = entries(overlapping: from, to, now: now)
        if let ref = try args.string("project"), !ref.isEmpty {
            let id = try project(ref).id
            entries = entries.filter { $0.project?.id == id }
        }
        if let ref = try args.string("customer"), !ref.isEmpty {
            let id = try customer(ref).id
            entries = entries.filter { $0.customer?.id == id }
        }
        if let ref = try args.string("role"), !ref.isEmpty {
            let id = try role(ref).id
            entries = entries.filter { $0.role?.id == id }
        }
        if let text = try args.string("text"), !text.isEmpty {
            entries = entries.filter {
                $0.title.localizedCaseInsensitiveContains(text) || ($0.notes ?? "").localizedCaseInsensitiveContains(text)
            }
        }
        if let review = try args.bool("needs_review") {
            entries = entries.filter { $0.needsReview == review }
        }
        let limit = min(max(try args.int("limit") ?? 50, 1), 500)
        return entries.sorted { $0.startAt > $1.startAt }.prefix(limit).map { json($0, now: now) }
    }

    private func listTodos(_ args: MCPArguments) throws -> [JSONObject] {
        let includeCompleted = try args.bool("include_completed") ?? false
        let projectID = try args.string("project").flatMap { $0.isEmpty ? nil : $0 }.map { try project($0).id }
        let roots = fetchAll(Todo.self).filter { $0.parent == nil }.sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.createdAt < $1.createdAt
        }
        var ordered: [Todo] = []
        func walk(_ todo: Todo) {
            ordered.append(todo)
            todo.orderedSubtasks.forEach(walk)
        }
        roots.forEach(walk)
        return ordered
            .filter { includeCompleted || !$0.isCompleted }
            .filter { projectID == nil || $0.relatedProject?.id == projectID }
            .map(json)
    }

    private func listMeetings(_ args: MCPArguments, now: Date = Date()) throws -> [JSONObject] {
        let to = try args.date("to") ?? now
        let from = try args.date("from") ?? Calendar.current.date(byAdding: .day, value: -14, to: to) ?? to
        let text = try args.string("text") ?? ""
        let limit = min(max(try args.int("limit") ?? 50, 1), 200)
        return fetchAll(MeetingRecord.self)
            .filter { $0.startedAt < to && ($0.endedAt ?? $0.startedAt) >= from }
            .filter {
                text.isEmpty || $0.title.localizedCaseInsensitiveContains(text)
                    || $0.participantNames.contains { $0.localizedCaseInsensitiveContains(text) }
            }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map(json)
    }

    private func getMeeting(_ args: MCPArguments) throws -> JSONObject {
        let record = try meeting(id: try args.requiredString("id"))
        var result = json(record)
        result["summary"] = record.namedSummary ?? record.summary
        result["participant_emails"] = record.participantEmails
        result["linked_entry"] = record.linkedEntryID.flatMap { try? entry(id: $0.uuidString) }.map { json($0) } ?? NSNull()
        let meetingID = record.id
        result["todo_proposals"] = fetchAll(TodoProposal.self).filter { $0.meetingID == meetingID }.map(json)
        return result
    }

    private func report(_ args: MCPArguments, now: Date = Date()) throws -> JSONObject {
        let name = try args.string("period").flatMap { $0.isEmpty ? nil : $0 } ?? "this_week"
        let period: Period
        switch name {
        case "today": period = .today
        case "this_week": period = .thisWeek
        case "last_week": period = .lastWeek
        case "this_month": period = .thisMonth
        case "last_month": period = .lastMonth
        case "custom":
            guard let from = try args.date("from"), let to = try args.date("to") else {
                throw ToolError("A custom period needs from and to.")
            }
            guard from < to else { throw ToolError("from must be before to.") }
            period = .custom(from: from, to: to)
        default:
            throw ToolError("period must be today, this_week, last_week, this_month, last_month or custom.")
        }
        let interval = period.interval(now: now)
        let report = AnalyticsAggregator.report(
            entries: entries(overlapping: interval.start, interval.end, now: now), period: period, now: now
        )
        func rows(_ rows: [BreakdownRow]) -> [JSONObject] {
            rows.map { ["name": $0.name, "hours": Self.hours($0.total), "billable_hours": Self.hours($0.billable)] }
        }
        return [
            "from": Self.format(interval.start),
            "to": Self.format(interval.end),
            "total_hours": Self.hours(report.totalSeconds),
            "billable_hours": Self.hours(report.billableSeconds),
            "entry_count": report.entryCount,
            "by_customer": rows(report.byCustomer),
            "by_project": rows(report.byProject),
            "by_role": rows(report.byRole),
            "note": "The running entry is not counted until it stops.",
        ]
    }
}
