import Foundation
import SwiftData

/// The tools an assistant can call, and the plumbing they share: argument parsing,
/// finding a project or todo by id or name, and turning models into JSON.
///
/// Reading and creating or editing only. There is deliberately no tool that deletes
/// anything; the user does that in Hansel.
@MainActor
final class MCPTools {

    struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    struct Tool {
        let name: String
        let title: String
        let description: String
        let properties: [String: JSONObject]
        let required: [String]
        let readOnly: Bool
        let run: (MCPArguments) throws -> Any
    }

    let context: ModelContext
    let controller: TimerController
    let proposals: ProposalService
    private(set) var tools: [Tool] = []

    init(context: ModelContext, controller: TimerController, proposals: ProposalService) {
        self.context = context
        self.controller = controller
        self.proposals = proposals
        tools = readTools() + writeTools()
    }

    var definitions: [JSONObject] {
        tools.map { tool in
            var schema: JSONObject = ["type": "object", "properties": tool.properties]
            if !tool.required.isEmpty { schema["required"] = tool.required }
            return [
                "name": tool.name,
                "title": tool.title,
                "description": tool.description,
                "inputSchema": schema,
                "annotations": [
                    "title": tool.title,
                    "readOnlyHint": tool.readOnly,
                    "destructiveHint": false,
                    "idempotentHint": tool.readOnly,
                    "openWorldHint": false,
                ],
            ]
        }
    }

    func has(_ name: String) -> Bool { tools.contains { $0.name == name } }

    /// Runs a tool. A failure is a result the assistant can read and recover from,
    /// not a protocol error.
    func call(_ name: String, arguments: JSONObject) -> JSONObject {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return Self.errorResult("Unknown tool: \(name)")
        }
        do {
            let value = try tool.run(MCPArguments(arguments))
            AppLogger.log("mcp", level: .info, "tool=\(name) ok")
            return ["content": [["type": "text", "text": Self.text(value)]], "isError": false]
        } catch let error as ToolError {
            AppLogger.log("mcp", level: .notice, "tool=\(name) rejected")
            return Self.errorResult(error.message)
        } catch {
            AppLogger.log("mcp", level: .warning, "tool=\(name) failed: \(error.localizedDescription)")
            return Self.errorResult(error.localizedDescription)
        }
    }

    private static func errorResult(_ message: String) -> JSONObject {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private static func text(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Schema helpers

    static func string(_ description: String) -> JSONObject {
        ["type": "string", "description": description]
    }

    static func boolean(_ description: String) -> JSONObject {
        ["type": "boolean", "description": description]
    }

    static func integer(_ description: String) -> JSONObject {
        ["type": "integer", "description": description]
    }

    static func choice(_ values: [String], _ description: String) -> JSONObject {
        ["type": "string", "enum": values, "description": description]
    }

    nonisolated static let dateHint = "ISO 8601, e.g. 2026-10-09T14:30 (local time when no offset) or 2026-10-09."
    nonisolated static let clearHint = "Pass an empty string to clear it."

    // MARK: - Lookups

    func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    /// One item by id or name: an exact name (any case) first, then a unique partial
    /// match. Ambiguity is an error naming the candidates, never a guess.
    func resolve<T>(
        _ reference: String,
        in items: [T],
        kind: String,
        id: (T) -> UUID,
        name: (T) -> String
    ) throws -> T {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: reference) {
            if let match = items.first(where: { id($0) == uuid }) { return match }
            throw ToolError("No \(kind) with id \(reference).")
        }
        let exact = items.filter { name($0).caseInsensitiveCompare(reference) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        let candidates = exact.isEmpty
            ? items.filter { name($0).localizedCaseInsensitiveContains(reference) }
            : exact
        if candidates.count == 1 { return candidates[0] }
        if candidates.isEmpty {
            let known = items.prefix(30).map { "\"\(name($0))\"" }.joined(separator: ", ")
            throw ToolError("No \(kind) named \"\(reference)\". Known: \(known.isEmpty ? "none" : known).")
        }
        let listed = candidates.prefix(10).map { "\"\(name($0))\" (\(id($0)))" }.joined(separator: ", ")
        throw ToolError("\"\(reference)\" matches several \(kind)s: \(listed). Use the id.")
    }

    func project(_ reference: String) throws -> Project {
        try resolve(reference, in: fetchAll(Project.self), kind: "project", id: \.id, name: \.name)
    }

    func customer(_ reference: String) throws -> Customer {
        try resolve(reference, in: fetchAll(Customer.self), kind: "customer", id: \.id, name: \.name)
    }

    func role(_ reference: String) throws -> Role {
        try resolve(reference, in: fetchAll(Role.self), kind: "role", id: \.id, name: \.name)
    }

    /// Open todos first, so a finished todo with the same title does not make the
    /// name ambiguous.
    func todo(_ reference: String) throws -> Todo {
        let all = fetchAll(Todo.self)
        let open = all.filter { !$0.isCompleted }
        if let match = try? resolve(reference, in: open, kind: "todo", id: \.id, name: \.title) {
            return match
        }
        return try resolve(reference, in: all, kind: "todo", id: \.id, name: \.title)
    }

    func entry(id reference: String) throws -> TimeEntry {
        guard let uuid = UUID(uuidString: reference) else { throw ToolError("\"\(reference)\" is not an entry id.") }
        let entry = (try? context.fetch(FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.id == uuid })))?.first
        guard let entry else { throw ToolError("No entry with id \(reference).") }
        return entry
    }

    func meeting(id reference: String) throws -> MeetingRecord {
        guard let uuid = UUID(uuidString: reference) else { throw ToolError("\"\(reference)\" is not a meeting id.") }
        let record = (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == uuid })))?.first
        guard let record else { throw ToolError("No meeting with id \(reference).") }
        return record
    }

    func proposal(id reference: String) throws -> TodoProposal {
        guard let uuid = UUID(uuidString: reference) else { throw ToolError("\"\(reference)\" is not a proposal id.") }
        let proposal = (try? context.fetch(FetchDescriptor<TodoProposal>(predicate: #Predicate { $0.id == uuid })))?.first
        guard let proposal else { throw ToolError("No todo proposal with id \(reference).") }
        return proposal
    }

    /// Entries overlapping [start, end), a running one counting until now.
    func entries(overlapping start: Date, _ end: Date, now: Date = Date()) -> [TimeEntry] {
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startAt < end },
            sortBy: [SortDescriptor(\.startAt)]
        )
        return ((try? context.fetch(descriptor)) ?? []).filter { ($0.endAt ?? now) > start }
    }

    /// Refuses times that would overlap another entry. The timeline has no overlaps,
    /// and an assistant should not reshape the user's other entries to make room.
    func checkNoOverlap(start: Date, end: Date, excluding id: UUID? = nil) throws {
        let conflicts = entries(overlapping: start, end).filter { $0.id != id }
        guard !conflicts.isEmpty else { return }
        let listed = conflicts.prefix(5).map { e in
            "\"\(e.title)\" \(Self.format(e.startAt))–\(e.endAt.map(Self.format) ?? "running") (\(e.id))"
        }.joined(separator: "; ")
        throw ToolError("Those times overlap other entries: \(listed). Adjust the times, or edit those entries first.")
    }

    // MARK: - JSON

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func value(_ date: Date?) -> Any { date.map(format) ?? NSNull() }
    static func value(_ string: String?) -> Any { string ?? NSNull() }

    static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }
    static func hours(_ seconds: TimeInterval) -> Double { (seconds / 36).rounded() / 100 }

    static func ref(_ id: UUID?, _ name: String?) -> Any {
        guard let id, let name else { return NSNull() }
        return ["id": id.uuidString, "name": name]
    }

    func json(_ entry: TimeEntry, now: Date = Date()) -> JSONObject {
        [
            "id": entry.id.uuidString,
            "title": entry.title,
            "start": Self.format(entry.startAt),
            "end": Self.value(entry.endAt),
            "running": entry.endAt == nil,
            "duration_minutes": Self.minutes((entry.endAt ?? now).timeIntervalSince(entry.startAt)),
            "project": Self.ref(entry.project?.id, entry.project?.name),
            "customer": Self.ref(entry.customer?.id, entry.customer?.name),
            "role": Self.ref(entry.role?.id, entry.role?.name),
            "todo": Self.ref(entry.linkedTodo?.id, entry.linkedTodo?.title),
            "billable": entry.billableCached,
            "notes": Self.value(entry.notes),
            "needs_review": entry.needsReview,
            "source": entry.source.rawValue,
        ]
    }

    func json(_ project: Project) -> JSONObject {
        [
            "id": project.id.uuidString,
            "name": project.name,
            "customer": Self.ref(project.customer?.id, project.customer?.name),
            "default_billable": project.defaultBillable,
            "details": project.details,
        ]
    }

    func json(_ customer: Customer) -> JSONObject {
        [
            "id": customer.id.uuidString,
            "name": customer.name,
            "default_billable": customer.defaultBillable,
            "email_domains": customer.emailDomains,
            "projects": customer.projects.map(\.name).sorted(),
        ]
    }

    func json(_ role: Role) -> JSONObject {
        ["id": role.id.uuidString, "name": role.name, "default_billable": role.defaultBillable]
    }

    func json(_ todo: Todo) -> JSONObject {
        [
            "id": todo.id.uuidString,
            "title": todo.title,
            "path": todo.breadcrumbPath,
            "parent_id": Self.value(todo.parent?.id.uuidString),
            "completed": todo.isCompleted,
            "completed_at": Self.value(todo.completedAt),
            "due": Self.value(todo.dueAt),
            "project": Self.ref(todo.relatedProject?.id, todo.relatedProject?.name),
            "notes": Self.value(todo.notes),
            "subtask_count": todo.subtasks.count,
        ]
    }

    func json(_ record: MeetingRecord) -> JSONObject {
        [
            "id": record.id.uuidString,
            "title": record.title,
            "start": Self.format(record.startedAt),
            "end": Self.value(record.endedAt),
            "participants": record.participantNames,
            "action_item_count": record.actionItemCount,
            "has_transcript": record.hasTranscript,
            "linked_entry_id": Self.value(record.linkedEntryID?.uuidString),
        ]
    }

    func json(_ proposal: TodoProposal) -> JSONObject {
        let projectName = proposal.projectID.flatMap { id in fetchAll(Project.self).first { $0.id == id }?.name }
        return [
            "id": proposal.id.uuidString,
            "status": proposal.status.rawValue,
            "title": proposal.title,
            "notes": proposal.notes,
            "due": Self.value(proposal.dueAt),
            "project": Self.ref(proposal.projectID, projectName),
            "meeting": ["id": proposal.meetingID.uuidString, "title": proposal.meetingTitle],
            "evidence": proposal.evidence,
            "owner": Self.value(proposal.owner),
            "likely_for_someone_else": proposal.likelyForSomeoneElse,
        ]
    }
}

/// A tool's arguments, with type checks that explain themselves to the assistant.
struct MCPArguments {
    let raw: JSONObject

    init(_ raw: JSONObject) { self.raw = raw }

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }

    func string(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        guard let value = raw[key] as? String else { throw MCPTools.ToolError("\(key) must be a string.") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key), !value.isEmpty else { throw MCPTools.ToolError("\(key) is required.") }
        return value
    }

    func bool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        guard let value = raw[key] as? Bool else { throw MCPTools.ToolError("\(key) must be true or false.") }
        return value
    }

    func int(_ key: String) throws -> Int? {
        guard has(key) else { return nil }
        guard let value = raw[key] as? NSNumber, !(raw[key] is Bool) else {
            throw MCPTools.ToolError("\(key) must be a whole number.")
        }
        return value.intValue
    }

    func date(_ key: String) throws -> Date? {
        guard let text = try string(key), !text.isEmpty else { return nil }
        guard let date = Self.parseDate(text) else {
            throw MCPTools.ToolError("\(key) \"\(text)\" is not a date. Use \(MCPTools.dateHint)")
        }
        return date
    }

    /// The text of an optional reference: nil when absent, "" when asked to clear.
    func reference(_ key: String) throws -> String? { try string(key) }

    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}
