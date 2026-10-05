import Foundation
import SwiftData

/// Orchestrator: pulls activity/idle/catalog/history from the store, calls the default AI
/// provider, returns an `EntryDraft` with role/project/customer resolved against the catalog.
@MainActor
final class SuggestionEngine {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func draft(
        from windowStart: Date,
        to windowEnd: Date,
        calendarEventTitle: String? = nil
    ) async throws -> EntryDraft {
        guard let provider = ProviderRegistry.defaultProvider() else {
            AppLogger.ai.warning("No AI provider configured — skipping draft")
            AppLogger.log("ai", level: .warning, "no_provider")
            throw AIError.noProviderConfigured
        }
        let ctx = loadContext(
            windowStart: windowStart,
            windowEnd: windowEnd,
            calendarEventTitle: calendarEventTitle
        )
        AppLogger.ai.info("Drafting via \(provider.displayName, privacy: .public) window=\(Int(windowEnd.timeIntervalSince(windowStart) / 60), privacy: .public)min samples=\(ctx.samples.count, privacy: .public)")
        AppLogger.log("ai", level: .info, "draft_begin provider=\(provider.displayName) samples=\(ctx.samples.count)")
        let draft = try await provider.draft(ctx)
        AppLogger.log("ai", level: .info, "draft_ok")
        return draft
    }

    private func loadContext(
        windowStart: Date,
        windowEnd: Date,
        calendarEventTitle: String?
    ) -> SuggestionContext {
        let samples = fetchSamples(from: windowStart, to: windowEnd)
        let idles = fetchIdles(touching: windowStart)
        let recent = fetchRecentEntries(limit: 50)
        let projects = (try? modelContext.fetch(FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\Project.name)]
        ))) ?? []
        let customers = (try? modelContext.fetch(FetchDescriptor<Customer>(
            sortBy: [SortDescriptor(\Customer.name)]
        ))) ?? []
        let roles = (try? modelContext.fetch(FetchDescriptor<Role>(
            sortBy: [SortDescriptor(\Role.name)]
        ))) ?? []
        let rules = (try? modelContext.fetch(FetchDescriptor<ClassificationRule>())) ?? []
        let hints = RuleEngine.evaluate(
            rules: rules,
            samples: samples,
            calendarEventTitle: calendarEventTitle
        )
        if !hints.isEmpty {
            AppLogger.ai.info("Rule hints: role=\(hints.role?.name ?? "-", privacy: .public) project=\(hints.project?.name ?? "-", privacy: .public) customer=\(hints.customer?.name ?? "-", privacy: .public)")
            AppLogger.log("ai", level: .info, "rule_hints role=\(hints.role?.name ?? "-") project=\(hints.project?.name ?? "-") customer=\(hints.customer?.name ?? "-")")
        }
        let allIncompleteTodos = (try? modelContext.fetch(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.isCompleted == false },
            sortBy: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)]
        ))) ?? []
        let rootTodos = allIncompleteTodos.filter { $0.parent == nil }
        return SuggestionContext(
            windowStart: windowStart,
            windowEnd: windowEnd,
            samples: samples,
            idleIntervals: idles,
            recentEntries: recent,
            projects: projects,
            customers: customers,
            roles: roles,
            calendarEventTitle: calendarEventTitle,
            fields: AISettingsStore.loadContextFields(),
            ruleHints: hints,
            activeTodos: rootTodos
        )
    }

    private func fetchSamples(from: Date, to: Date) -> [ActivitySample] {
        let descriptor = FetchDescriptor<ActivitySample>(
            predicate: #Predicate<ActivitySample> { $0.timestamp >= from && $0.timestamp <= to },
            sortBy: [SortDescriptor(\ActivitySample.timestamp)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchIdles(touching since: Date) -> [IdleInterval] {
        let all = (try? modelContext.fetch(FetchDescriptor<IdleInterval>())) ?? []
        return all.filter { ($0.end ?? Date()) >= since }
    }

    /// Few-shot examples for the classification prompt. Filters on `isHumanConfirmed`,
    /// NOT `isConfirmed` — the latter is true for every auto-created entry that merely
    /// ran to completion, which would feed the model its own past guesses as ground truth.
    private func fetchRecentEntries(limit: Int) -> [TimeEntry] {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.isHumanConfirmed == true },
            sortBy: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
