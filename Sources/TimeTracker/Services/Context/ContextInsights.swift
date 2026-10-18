import Foundation

/// What the dossiers and context items say about the user's work, for the Dashboard and
/// Analytics: each todo's next steps, the time spent on it, and per customer how much
/// was tracked against how much happened.
enum ContextInsights {

    // MARK: - Next steps

    /// The bullets of a dossier's "## Next steps" section, without "None.".
    static func nextSteps(in dossier: String, limit: Int = 3) -> [String] {
        var steps: [String] = []
        var inSection = false
        for raw in dossier.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inSection = line == "## Next steps"
                continue
            }
            guard inSection, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let step = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !step.isEmpty, step.lowercased() != "none." { steps.append(step) }
            if steps.count == limit { break }
        }
        return steps
    }

    // MARK: - Time per todo

    /// Entries that count for a todo: linked to it or one of its subtasks, or on its
    /// project and linked to no todo (time is often logged on the project alone).
    @MainActor
    static func entries(for todo: Todo, in entries: [TimeEntry]) -> [TimeEntry] {
        let ids = Set(DossierService.subtree(todo).map(\.id))
        let project = todo.inheritedProject
        return entries.filter { entry in
            guard entry.supersededByID == nil else { return false }
            if let linked = entry.linkedTodo { return ids.contains(linked.id) }
            return project != nil && entry.project?.id == project?.id
        }
    }

    static func seconds(_ entries: [TimeEntry], in interval: DateInterval? = nil, now: Date = Date()) -> TimeInterval {
        entries.reduce(0) { sum, entry in
            let end = entry.endAt ?? now
            guard let interval else { return sum + end.timeIntervalSince(entry.startAt) }
            let overlap = min(end, interval.end).timeIntervalSince(max(entry.startAt, interval.start))
            return sum + max(0, overlap)
        }
    }

    // MARK: - Analytics

    struct CustomerLine: Identifiable, Equatable {
        var id: UUID
        var name: String
        var trackedSeconds: TimeInterval
        var items: Int
        var bySource: [ContextItem.Source: Int]
        var lastActivity: Date?
    }

    struct TodoLine: Identifiable, Equatable {
        var id: UUID
        var path: String
        var customer: String?
        var trackedSeconds: TimeInterval
        var items: Int
        var dossierUpdatedAt: Date?
    }

    struct Report: Equatable {
        var customers: [CustomerLine]
        var todos: [TodoLine]
        var bySource: [(source: ContextItem.Source, count: Int)]
        var collected: Int
        /// How the period's items were placed.
        var placedAutomatically: Int
        var corrected: Int
        var waiting: Int
        var discarded: Int

        static func == (a: Report, b: Report) -> Bool {
            a.customers == b.customers && a.todos == b.todos && a.collected == b.collected
                && a.bySource.map(\.count) == b.bySource.map(\.count)
        }
    }

    /// Items that happened in `interval` and the time tracked in it, per customer and per
    /// open todo. Customers kept out of AI context are left out.
    @MainActor
    static func report(items: [ContextItem], todos: [Todo], customers: [Customer], entries: [TimeEntry],
                       interval: DateInterval, now: Date = Date()) -> Report {
        let hidden = Set(customers.filter(\.excludedFromContext).map(\.id))
        let todoByID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let inPeriod = items.filter { interval.contains($0.occurredAt) && !($0.customerID.map(hidden.contains) ?? false) }
        let entriesInPeriod = entries.filter { entry in
            (entry.endAt ?? now) > interval.start && entry.startAt < interval.end
        }

        func customerID(of item: ContextItem) -> UUID? {
            item.customerID ?? item.todoID.flatMap { todoByID[$0] }?.effectiveCustomer?.id
        }

        let customerLines = customers.filter { !$0.excludedFromContext }.compactMap { customer -> CustomerLine? in
            let theirItems = inPeriod.filter { $0.status == .assigned && customerID(of: $0) == customer.id }
            let theirEntries = entriesInPeriod.filter { ($0.customer ?? $0.project?.customer)?.id == customer.id }
            let tracked = seconds(theirEntries, in: interval, now: now)
            guard !theirItems.isEmpty || tracked > 0 else { return nil }
            return CustomerLine(
                id: customer.id, name: customer.name, trackedSeconds: tracked, items: theirItems.count,
                bySource: Dictionary(grouping: theirItems, by: \.source).mapValues(\.count),
                lastActivity: theirItems.map(\.occurredAt).max()
            )
        }
        .sorted { ($0.trackedSeconds, $0.items) > ($1.trackedSeconds, $1.items) }

        let todoLines = todos.filter { $0.parent == nil && !$0.isCompleted && !$0.isExcludedFromContext }
            .compactMap { todo -> TodoLine? in
                let ids = Set(DossierService.subtree(todo).map(\.id))
                let theirItems = inPeriod.filter { $0.status == .assigned && ($0.todoID.map(ids.contains) ?? false) }
                let tracked = seconds(Self.entries(for: todo, in: entriesInPeriod), in: interval, now: now)
                guard !theirItems.isEmpty || tracked > 0 else { return nil }
                return TodoLine(id: todo.id, path: todo.breadcrumbPath, customer: todo.effectiveCustomer?.name,
                                trackedSeconds: tracked, items: theirItems.count,
                                dossierUpdatedAt: todo.dossierUpdatedAt)
            }
            .sorted { ($0.trackedSeconds, $0.items) > ($1.trackedSeconds, $1.items) }

        let sources = Dictionary(grouping: inPeriod.filter { $0.status != .discarded }, by: \.source)
            .map { (source: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        return Report(
            customers: customerLines,
            todos: todoLines,
            bySource: sources,
            collected: inPeriod.count,
            placedAutomatically: inPeriod.filter { $0.status == .assigned && $0.assignedBy != .user }.count,
            corrected: inPeriod.filter { $0.assignedBy == .user && $0.status == .assigned }.count,
            waiting: inPeriod.filter { $0.status == .unassigned }.count,
            discarded: inPeriod.filter { $0.status == .discarded }.count
        )
    }
}
