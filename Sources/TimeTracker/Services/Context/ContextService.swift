import Foundation
import Observation
import SwiftData

/// Keeps the context items: takes what the assistant collected from Slack, email,
/// Teams, the calendar and Confluence, turns Hansel's own meetings into items, assigns
/// each to a todo or customer (`ContextClassifier`), and records the user's decisions
/// in the inbox so the next collection learns from them.
///
/// Makes no model calls: the assistant that read the sources has already summarised
/// them, and Hansel's part is to check its suggestions against the closed lists.
@Observable
@MainActor
final class ContextService {

    /// One item as the assistant sends it.
    struct Incoming {
        var source: ContextItem.Source
        var externalID: String
        var url: String?
        var title: String
        var occurredAt: Date
        var participants: [String]
        var channel: String?
        var summary: String
        var details: String
        var suggestedTodoID: UUID?
        var suggestedCustomer: String?
        var confidence: Double?
        var reason: String?
    }

    struct Outcome {
        var externalID: String
        var status: String
        var todo: Todo?
        var customer: Customer?
        var reason: String
    }

    static let summaryLimit = 500
    static let detailsLimit = 2000
    /// How far back the first collection from a source reaches.
    static let firstCollectionDays: Double = 14
    private static let cursorPrefix = "context.cursor."

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let defaults: UserDefaults

    init(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
    }

    // MARK: - Collection cursors

    /// Where the next collection from `source` starts: the end of the last one that
    /// finished, so a Mac asleep for a day misses nothing.
    func since(_ source: ContextItem.Source, now: Date = Date()) -> Date {
        let stored = defaults.object(forKey: Self.cursorPrefix + source.rawValue) as? Date
        return stored ?? now.addingTimeInterval(-Self.firstCollectionDays * 86_400)
    }

    func markCollected(_ source: ContextItem.Source, through date: Date, now: Date = Date()) {
        // Never in the future, never backwards.
        let clamped = min(date, now)
        guard clamped > since(source, now: now) else { return }
        defaults.set(clamped, forKey: Self.cursorPrefix + source.rawValue)
    }

    // MARK: - From the assistant

    /// Saves each item, or updates the one with the same source and id, and assigns it.
    /// Items about a customer kept out of AI context are not stored (and an earlier copy
    /// is removed).
    @discardableResult
    func ingest(_ incoming: [Incoming], now: Date = Date()) -> [Outcome] {
        let catalog = Catalog(context: modelContext)
        var outcomes: [Outcome] = []
        for raw in incoming {
            let input = ContextClassifier.Input(
                title: raw.title, summary: raw.summary, participants: raw.participants, channel: raw.channel,
                suggestedTodoID: raw.suggestedTodoID, suggestedCustomer: raw.suggestedCustomer,
                suggestedConfidence: raw.confidence
            )
            let existing = item(source: raw.source, externalID: raw.externalID)
            let decision = ContextClassifier.classify(input, customers: catalog.customers, todos: catalog.openTodos)
            if decision.outcome == .drop {
                if let existing { modelContext.delete(existing) }
                outcomes.append(Outcome(externalID: raw.externalID, status: "skipped", reason: decision.reason))
                continue
            }
            let item = existing ?? {
                let made = ContextItem(source: raw.source, externalID: raw.externalID, title: raw.title,
                                       occurredAt: raw.occurredAt, summary: "", now: now)
                modelContext.insert(made)
                return made
            }()
            item.url = raw.url?.isEmpty == false ? raw.url : item.url
            item.title = raw.title
            item.occurredAt = raw.occurredAt
            item.participants = raw.participants
            item.channel = raw.channel
            item.summary = Self.clip(raw.summary, Self.summaryLimit)
            item.details = Self.clip(raw.details, Self.detailsLimit)
            item.updatedAt = now
            if !item.isUserDecided {
                apply(decision, to: item, assistantReason: raw.reason)
                item.suggestedConfidence = raw.confidence
            }
            outcomes.append(outcome(for: item, catalog: catalog))
        }
        try? modelContext.save()
        AppLogger.log("context", level: .info, "ingested count=\(incoming.count)")
        return outcomes
    }

    private func apply(_ decision: ContextClassifier.Decision, to item: ContextItem, assistantReason: String?) {
        switch decision.outcome {
        case let .assigned(todoID, customerID):
            item.status = .assigned
            item.todoID = todoID
            item.customerID = customerID
        case .inbox, .drop:
            item.status = .unassigned
            item.todoID = nil
            item.customerID = decision.suggestedCustomerID
        }
        item.confidence = decision.confidence
        item.assignedBy = decision.assignedBy
        let why = assistantReason.flatMap { $0.isEmpty ? nil : " Assistant: \($0)" } ?? ""
        item.reason = decision.reason + why
        item.suggestedTodoID = decision.suggestedTodoID
        item.suggestedCustomerID = decision.suggestedCustomerID
        item.proposedCustomerName = decision.proposedCustomerName
    }

    private func outcome(for item: ContextItem, catalog: Catalog) -> Outcome {
        Outcome(
            externalID: item.externalID,
            status: item.status.rawValue,
            todo: item.todoID.flatMap { id in catalog.todos.first { $0.id == id } },
            customer: item.customerID.flatMap { id in catalog.customers.first { $0.id == id } },
            reason: item.reason
        )
    }

    // MARK: - From Hansel's meetings

    /// Makes or refreshes an item for every finished meeting, assigned by what Hansel
    /// already knows: the todos accepted from its proposals, the todo of its time entry,
    /// then the attendees' domains and the customer names in its title and summary.
    func syncMeetings(now: Date = Date()) {
        let records = ((try? modelContext.fetch(FetchDescriptor<MeetingRecord>())) ?? [])
            .filter { $0.endedAt != nil && $0.status != "failed" }
        guard !records.isEmpty else { return }
        let catalog = Catalog(context: modelContext)
        let accepted = ((try? modelContext.fetch(FetchDescriptor<TodoProposal>())) ?? [])
            .filter { $0.status == .accepted && $0.acceptedTodoID != nil }
        let entries = (try? modelContext.fetch(FetchDescriptor<TimeEntry>())) ?? []
        var changed = 0
        for record in records {
            let existing = item(source: .meeting, externalID: record.id.uuidString)
            let todoIDs = accepted.filter { $0.meetingID == record.id }.compactMap(\.acceptedTodoID)
            let linkedTodo = record.linkedEntryID.flatMap { id in entries.first { $0.id == id } }?.linkedTodo
            let decision = Self.meetingDecision(
                record: record, acceptedTodoIDs: todoIDs, linkedTodo: linkedTodo, catalog: catalog
            )
            if decision.outcome == .drop {
                if let existing { modelContext.delete(existing); changed += 1 }
                continue
            }
            let item = existing ?? {
                let made = ContextItem(source: .meeting, externalID: record.id.uuidString, title: record.title,
                                       occurredAt: record.startedAt, summary: "", now: now)
                modelContext.insert(made)
                return made
            }()
            // Tasks the user filed under a personal todo stay out of the details.
            let personal = Set(accepted.filter { proposal in
                proposal.meetingID == record.id
                    && (proposal.acceptedTodoID.flatMap { id in catalog.todos.first { $0.id == id } }?.isExcludedFromContext ?? false)
            }.map(\.evidence))
            let version = Self.version(of: record) + "|\(personal.count)"
            if item.sourceVersion != version {
                fillMeetingContent(item, record: record, leaving: personal)
                item.sourceVersion = version
                item.updatedAt = now
                changed += 1
            }
            if !item.isUserDecided, Self.differs(decision, from: item) {
                apply(decision, to: item, assistantReason: nil)
                item.updatedAt = now
                changed += 1
            }
        }
        if changed > 0 {
            try? modelContext.save()
            AppLogger.log("context", level: .info, "meetings_synced changed=\(changed)")
        }
    }

    /// Meeting Notes removed these meetings, so their items go too.
    func meetingsRemoved(_ ids: [UUID]) {
        let keys = Set(ids.map { ContextItem.key(source: .meeting, externalID: $0.uuidString) })
        let doomed = ((try? modelContext.fetch(FetchDescriptor<ContextItem>())) ?? []).filter { keys.contains($0.sourceKey) }
        guard !doomed.isEmpty else { return }
        doomed.forEach { modelContext.delete($0) }
        try? modelContext.save()
    }

    static func meetingDecision(
        record: MeetingRecord, acceptedTodoIDs: [UUID], linkedTodo: Todo?, catalog: Catalog
    ) -> ContextClassifier.Decision {
        // The todos the user accepted from this meeting say best what it was about:
        // the top-level todo most of them sit under. A meeting is left out only when
        // everything taken from it is personal; one personal task does not hide the rest.
        let acceptedRoots = acceptedTodoIDs.compactMap { id in catalog.todos.first { $0.id == id } }.map(\.root)
        let entryRoot = linkedTodo?.root
        let all = acceptedRoots + [entryRoot].compactMap { $0 }
        if !all.isEmpty, all.allSatisfy(\.isExcludedFromContext) {
            return .init(outcome: .drop, reason: "Kept out of AI context.")
        }
        let usable: (Todo) -> Bool = { !$0.isExcludedFromContext && $0.effectiveCustomer != nil }
        let fromProposals = Dictionary(grouping: acceptedRoots.filter(usable), by: \.id)
            .max { $0.value.count < $1.value.count }?.value.first
        let fromEntry = entryRoot.flatMap { usable($0) ? $0 : nil }
        if let todo = fromProposals ?? fromEntry {
            if let customer = todo.effectiveCustomer {
                return .init(
                    outcome: .assigned(todoID: todo.id, customerID: customer.id), confidence: 0.95,
                    assignedBy: .rules,
                    reason: fromProposals != nil ? "Its tasks were added to \(todo.title)." : "Its time entry is on \(todo.title)."
                )
            }
        }
        let input = ContextClassifier.Input(
            title: record.title, summary: record.namedSummary ?? record.summary,
            participants: record.participantEmails
        )
        return ContextClassifier.classify(input, customers: catalog.customers, todos: catalog.openTodos)
    }

    private static func differs(_ decision: ContextClassifier.Decision, from item: ContextItem) -> Bool {
        let (status, todoID, customerID): (ContextItem.Status, UUID?, UUID?) = {
            switch decision.outcome {
            case let .assigned(todo, customer): return (.assigned, todo, customer)
            default: return (.unassigned, nil, decision.suggestedCustomerID)
            }
        }()
        return item.status != status || item.todoID != todoID || item.customerID != customerID
            || item.reason != decision.reason
    }

    private static func version(of record: MeetingRecord) -> String {
        "\(record.fileModifiedAt.timeIntervalSince1970)|\(record.title)|\((record.namedSummary ?? "").count)|\(record.participantEmails.count)"
    }

    /// Summary: the first lines of the (named) summary. Details: decisions, action
    /// items and open questions from the archive, when it can be read.
    private func fillMeetingContent(_ item: ContextItem, record: MeetingRecord, leaving personal: Set<String> = []) {
        item.title = record.title
        item.occurredAt = record.startedAt
        item.participants = record.participantEmails.isEmpty ? record.participantNames : record.participantEmails
        item.url = record.folderURL.appending(path: "meeting.md").absoluteString
        let summary = record.namedSummary ?? record.summary
        item.summary = Self.clip(Self.firstSentences(summary, count: 2), Self.summaryLimit)
        var lines: [String] = []
        if let insights = (try? MeetingNotesArchive.load(record.folderURL))?.insights {
            if !insights.decisions.isEmpty {
                lines.append("Decisions:")
                lines += insights.decisions.map { "- \($0.text)" }
            }
            if !insights.actionItems.isEmpty {
                lines.append("Action items:")
                lines += insights.actionItems.filter { !personal.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .map { "- \($0.text)" + ($0.owner.map { " (\($0))" } ?? "") }
            }
            if !insights.openQuestions.isEmpty {
                lines.append("Open questions:")
                lines += insights.openQuestions.map { "- \($0.text)" }
            }
        }
        item.details = Self.clip(lines.isEmpty ? summary : lines.joined(separator: "\n"), Self.detailsLimit)
    }

    // MARK: - The user's decisions

    func assign(_ item: ContextItem, todo: Todo, now: Date = Date()) {
        item.status = .assigned
        item.todoID = todo.id
        item.customerID = todo.effectiveCustomer?.id
        decided(item, now: now)
    }

    func assign(_ item: ContextItem, customer: Customer, now: Date = Date()) {
        item.status = .assigned
        item.todoID = nil
        item.customerID = customer.id
        decided(item, now: now)
    }

    func discard(_ item: ContextItem, now: Date = Date()) {
        item.status = .discarded
        item.todoID = nil
        decided(item, now: now)
    }

    /// Back to the inbox, and to Hansel's own judgement on the next update.
    func reopen(_ item: ContextItem) {
        item.status = .unassigned
        item.resolvedByUserAt = nil
        item.sourceVersion = nil
        try? modelContext.save()
    }

    private func decided(_ item: ContextItem, now: Date) {
        // A newly placed item is new to that todo's dossier.
        item.updatedAt = now
        item.assignedBy = .user
        item.confidence = 1
        item.resolvedByUserAt = now
        item.reason = "Decided by you."
        try? modelContext.save()
    }

    /// Aliases that would have found `customer` for this item: its people's email
    /// domains and its channel, when no customer has them yet and they are not the
    /// user's own or a public mail domain.
    func aliasCandidates(for item: ContextItem, customer: Customer) -> [String] {
        let customers = (try? modelContext.fetch(FetchDescriptor<Customer>())) ?? []
        let mine = Set(Self.userEmails(defaults: defaults).compactMap(CustomerMatcher.domain(ofEmail:)))
        var candidates: [String] = []
        for domain in item.participants.compactMap(CustomerMatcher.domain(ofEmail:)) {
            guard !mine.contains(domain), !Self.publicMailDomains.contains(domain), !candidates.contains(domain) else { continue }
            candidates.append(domain)
        }
        if let channel = item.channel?.trimmingCharacters(in: .whitespaces), !channel.isEmpty {
            candidates.append(channel.hasPrefix("#") ? channel : "#" + channel)
        }
        return candidates.filter {
            CustomerMatcher.conflict(name: nil, aliases: $0, excluding: nil, in: customers) == nil
        }
    }

    /// Adds `alias` to the customer. False when another customer goes by it.
    @discardableResult
    func addAlias(_ alias: String, to customer: Customer) -> Bool {
        guard HanselActions.customerConflict(aliases: alias, excluding: customer, context: modelContext) == nil else {
            return false
        }
        let current = customer.aliases.trimmingCharacters(in: .whitespaces)
        customer.aliases = current.isEmpty ? alias : current + ", " + alias
        try? modelContext.save()
        return true
    }

    static let publicMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "icloud.com", "me.com",
        "yahoo.com", "proton.me", "protonmail.com", "msn.com",
    ]

    static func userEmails(defaults: UserDefaults = .standard) -> [String] {
        (defaults.string(forKey: "calendar.myEmails") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") }
    }

    // MARK: - Reading

    func item(source: ContextItem.Source, externalID: String) -> ContextItem? {
        let key = ContextItem.key(source: source, externalID: externalID)
        return (try? modelContext.fetch(FetchDescriptor<ContextItem>(predicate: #Predicate { $0.sourceKey == key })))?.first
    }

    /// The user's latest inbox decisions, newest first.
    func recentDecisions(limit: Int = 20) -> [ContextItem] {
        let all = (try? modelContext.fetch(FetchDescriptor<ContextItem>())) ?? []
        return Array(all.filter { $0.resolvedByUserAt != nil }
            .sorted { ($0.resolvedByUserAt ?? .distantPast) > ($1.resolvedByUserAt ?? .distantPast) }
            .prefix(limit))
    }

    // MARK: - Helpers

    /// Customers and todos as the classifier needs them.
    struct Catalog {
        var customers: [Customer]
        var todos: [Todo]
        var openTodos: [Todo] { todos.filter { !$0.isCompleted } }

        init(customers: [Customer], todos: [Todo]) {
            self.customers = customers
            self.todos = todos
        }

        @MainActor init(context: ModelContext) {
            customers = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
            todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    static func firstSentences(_ text: String, count: Int) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if sentences.count >= count { stop = true }
        }
        return sentences.isEmpty ? text : sentences.joined(separator: " ")
    }
}
