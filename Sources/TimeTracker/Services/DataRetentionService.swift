import Foundation
import SwiftData

/// Prunes high-volume telemetry that nothing reads after a while.
///
/// `ActivitySample` grows by roughly one row per 30 s of active use and is never
/// deleted, while `DayTimelineView` loads the whole table to render a single day.
/// Left alone this degrades the app long before the AI work does.
///
/// Time entries, todos and the catalog are never touched — only derived signals.
@MainActor
enum DataRetentionService {
    /// Samples older than this are dropped. Long enough for the segmenter's longest
    /// look-back and for a few weeks of retrospective review.
    static let sampleRetentionDays = 30
    /// Idle spans are far smaller; keep them longer for analytics.
    static let idleRetentionDays = 90
    /// Calendar links only exist to de-duplicate firing; they are worthless once stale.
    static let calendarLinkRetentionDays = 30

    private static let lastRunKey = "retention.lastRunAt"

    /// Runs at most once every 12 h. Safe to call on every launch.
    static func runIfDue(modelContext: ModelContext, now: Date = Date()) {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastRunKey) as? Date,
           now.timeIntervalSince(last) < 12 * 3600 {
            return
        }
        defaults.set(now, forKey: lastRunKey)
        run(modelContext: modelContext, now: now)
    }

    static func run(modelContext: ModelContext, now: Date = Date()) {
        let sampleCutoff = now.addingTimeInterval(-Double(sampleRetentionDays) * 86_400)
        let idleCutoff = now.addingTimeInterval(-Double(idleRetentionDays) * 86_400)
        let linkCutoff = now.addingTimeInterval(-Double(calendarLinkRetentionDays) * 86_400)

        var deleted = 0
        deleted += delete(FetchDescriptor<ActivitySample>(
            predicate: #Predicate { $0.timestamp < sampleCutoff }
        ), in: modelContext)
        deleted += delete(FetchDescriptor<IdleInterval>(
            predicate: #Predicate { $0.start < idleCutoff }
        ), in: modelContext)
        deleted += delete(FetchDescriptor<CalendarEventLink>(
            predicate: #Predicate { $0.lastSeenStart < linkCutoff }
        ), in: modelContext)

        guard deleted > 0 else { return }
        do {
            try modelContext.save()
            AppLogger.persistence.info("Retention pruned \(deleted, privacy: .public) rows")
            AppLogger.log("persistence", level: .info, "retention_pruned count=\(deleted)")
        } catch {
            AppLogger.persistence.error("Retention save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func delete<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in modelContext: ModelContext
    ) -> Int {
        guard let rows = try? modelContext.fetch(descriptor), !rows.isEmpty else { return 0 }
        rows.forEach { modelContext.delete($0) }
        return rows.count
    }
}
