import Foundation
import SwiftData

/// Adapts SwiftData and the live services to the value types `FocusArbiter` works with.
///
/// Keeping this separate is what lets the arbiter hold no `ModelContext` and therefore
/// be tested with plain arrays.
@MainActor
final class FocusStore {

    private let modelContext: ModelContext
    private weak var timerController: TimerController?
    private weak var meetingProvider: MeetingProvider?

    init(
        modelContext: ModelContext,
        timerController: TimerController,
        meetingProvider: MeetingProvider
    ) {
        self.modelContext = modelContext
        self.timerController = timerController
        self.meetingProvider = meetingProvider
    }

    // MARK: - Reads

    func samples(from: Date, to: Date) -> [SignalSample] {
        let descriptor = FetchDescriptor<ActivitySample>(
            predicate: #Predicate<ActivitySample> { $0.timestamp >= from && $0.timestamp <= to },
            sortBy: [SortDescriptor(\ActivitySample.timestamp)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map {
            SignalSample(
                timestamp: $0.timestamp,
                bundleId: $0.bundleId,
                appName: $0.appName,
                windowTitle: $0.windowTitle,
                url: $0.url,
                flags: $0.flags
            )
        }
    }

    func idleSpans(from: Date, to: Date) -> [IdleSpan] {
        // Bounded in the store: only spans that can overlap the window. Open spans
        // (end == nil) are the one in progress, so they always qualify.
        let descriptor = FetchDescriptor<IdleInterval>(
            predicate: #Predicate<IdleInterval> { $0.start <= to && ($0.end ?? to) >= from },
            sortBy: [SortDescriptor(\IdleInterval.start)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map { IdleSpan(start: $0.start, end: $0.end) }
    }

    func currentEntry() -> EntryContext? {
        guard let entry = timerController?.runningEntry else { return nil }
        return EntryContext(
            id: entry.id,
            title: entry.title,
            startAt: entry.startAt,
            roleName: entry.role?.name,
            projectName: entry.project?.name,
            customerName: entry.customer?.name,
            todoTitle: entry.linkedTodo?.title
        )
    }

    func runningEntry() -> TimeEntry? { timerController?.runningEntry }

    // MARK: - Boundary context

    func buildBoundaryContext(
        for candidate: ContextSegmenter.BoundaryCandidate,
        now: Date = Date()
    ) -> BoundaryContext? {
        let windowStart = candidate.at.addingTimeInterval(-900)
        let before = samples(from: windowStart, to: candidate.at)
        let after = samples(from: candidate.at, to: now)

        let meeting = candidate.meetingEventId.flatMap { id in
            meetingProvider?.meetings(from: windowStart, to: now.addingTimeInterval(3600))
                .first { $0.eventId == id }
        }

        let rules = (try? modelContext.fetch(FetchDescriptor<ClassificationRule>())) ?? []
        let sampleRows = fetchSampleRows(from: windowStart, to: now)
        let hints = RuleEngine.evaluate(rules: rules, samples: sampleRows,
                                        calendarEventTitle: meeting?.title)

        let todos = (try? modelContext.fetch(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.isCompleted == false },
            sortBy: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)]
        ))) ?? []

        var recentDescriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.isHumanConfirmed == true },
            sortBy: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
        )
        recentDescriptor.fetchLimit = 25

        return BoundaryContext(
            currentEntry: currentEntry(),
            boundaryAt: candidate.at,
            segmenterScore: candidate.score,
            reasons: candidate.reasons,
            before: before,
            after: after,
            idleSpans: idleSpans(from: windowStart, to: now),
            meeting: meeting,
            meetingCorroborated: candidate.isHard,
            projects: (try? modelContext.fetch(FetchDescriptor<Project>(
                sortBy: [SortDescriptor(\Project.name)]))) ?? [],
            customers: (try? modelContext.fetch(FetchDescriptor<Customer>(
                sortBy: [SortDescriptor(\Customer.name)]))) ?? [],
            roles: (try? modelContext.fetch(FetchDescriptor<Role>(
                sortBy: [SortDescriptor(\Role.name)]))) ?? [],
            activeTodos: todos.filter { $0.parent == nil },
            recentEntries: (try? modelContext.fetch(recentDescriptor)) ?? [],
            ruleHints: hints,
            corrections: recentCorrections(),
            now: now,
            // The model may refine the machine's instant within ten minutes either way;
            // it may not invent one somewhere else entirely.
            earliestAllowed: max(
                candidate.at.addingTimeInterval(-600),
                (currentEntry()?.startAt ?? candidate.at).addingTimeInterval(180)
            ),
            latestAllowed: now
        )
    }

    private func fetchSampleRows(from: Date, to: Date) -> [ActivitySample] {
        let descriptor = FetchDescriptor<ActivitySample>(
            predicate: #Predicate<ActivitySample> { $0.timestamp >= from && $0.timestamp <= to },
            sortBy: [SortDescriptor(\ActivitySample.timestamp)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Learning

    /// Recent proposals the user rejected or corrected, plus a few they accepted so the
    /// model is not taught that everything it does is wrong.
    func recentCorrections(limit: Int = 15) -> [BoundaryCorrectionExample] {
        var descriptor = FetchDescriptor<FocusDecision>(
            predicate: #Predicate<FocusDecision> { $0.userResponseRaw != nil },
            sortBy: [SortDescriptor(\FocusDecision.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit * 3
        let rows = (try? modelContext.fetch(descriptor)) ?? []

        let negatives = rows.filter {
            $0.userResponse == .keptCurrent || $0.userResponse == .switchedEdited
                || $0.userResponse == .undone
        }
        let positives = rows.filter { $0.userResponse == .switched }

        return (negatives.prefix(limit - 5) + positives.prefix(5)).map { decision in
            BoundaryCorrectionExample(
                reason: decision.bucket,
                evidence: decision.evidence,
                proposedTitle: decision.proposedTitle,
                correctedTitle: decision.correctedTitle,
                accepted: decision.userResponse == .switched
            )
        }
    }

    /// Transitions the user has rejected repeatedly. Fed back into the segmenter so a
    /// stubbornly wrong signal silences itself without a code change.
    ///
    /// Keyed on the stored `transition` (`"before>after"`), the same format the
    /// segmenter checks. It used to key on the free-text evidence, which includes the
    /// score, so no two rows ever matched and nothing was ever suppressed.
    func suppressedTransitions(rejectionThreshold: Int = 3) -> Set<String> {
        let now = Date()
        // Cached: this runs on every arbiter tick and the log only grows.
        if let cached = suppressionCache, now.timeIntervalSince(cached.at) < 300 {
            return cached.value
        }
        let since = now.addingTimeInterval(-60 * 86_400)
        var descriptor = FetchDescriptor<FocusDecision>(
            predicate: #Predicate<FocusDecision> {
                $0.userResponseRaw != nil && $0.transition != nil && $0.createdAt >= since
            }
        )
        descriptor.fetchLimit = 2000
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        var rejections: [String: Int] = [:]
        var acceptances: [String: Int] = [:]
        for row in rows {
            guard let key = row.transition, !key.isEmpty else { continue }
            if row.userResponse == .keptCurrent { rejections[key, default: 0] += 1 }
            if row.userResponse == .switched { acceptances[key, default: 0] += 1 }
        }
        let value = Set(
            rejections
                .filter { $0.value >= rejectionThreshold && acceptances[$0.key, default: 0] == 0 }
                .keys
        )
        suppressionCache = (now, value)
        return value
    }

    private var suppressionCache: (at: Date, value: Set<String>)?

    // MARK: - Writes

    func record(_ decision: FocusDecision) {
        modelContext.insert(decision)
        try? modelContext.save()
    }

    func decision(id: UUID) -> FocusDecision? {
        let descriptor = FetchDescriptor<FocusDecision>(
            predicate: #Predicate<FocusDecision> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Resolves the model's catalog names back to objects for a switch.
    func plan(from proposal: FocusPolicy.Proposal) -> TimerController.EntryPlan {
        let roles = (try? modelContext.fetch(FetchDescriptor<Role>())) ?? []
        let projects = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        let customers = (try? modelContext.fetch(FetchDescriptor<Customer>())) ?? []
        let todos = (try? modelContext.fetch(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.isCompleted == false },
            sortBy: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)]
        ))) ?? []

        let project = projects.first { $0.name.caseInsensitiveCompare(proposal.project ?? "") == .orderedSame }
        return TimerController.EntryPlan(
            title: proposal.title ?? "",
            role: roles.first { $0.name.caseInsensitiveCompare(proposal.role ?? "") == .orderedSame },
            project: project,
            customer: customers.first { $0.name.caseInsensitiveCompare(proposal.customer ?? "") == .orderedSame }
                ?? project?.customer,
            todo: resolveTodo(proposal.todo, roots: todos.filter { $0.parent == nil })
        )
    }

    private func resolveTodo(_ key: String?, roots: [Todo]) -> Todo? {
        guard let key, !key.isEmpty else { return nil }
        let indexed = PromptBuilder.flattenTodos(roots: roots)
        if let hit = indexed.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            return hit.todo
        }
        let matches = indexed.filter { $0.todo.title.caseInsensitiveCompare(key) == .orderedSame }
        return matches.count == 1 ? matches[0].todo : nil
    }
}
