import Foundation
import SwiftData

/// One-time fixes to data written by older versions. Each step runs once per install,
/// guarded by its own UserDefaults flag.
@MainActor
enum DataMaintenance {

    static func runPending(context: ModelContext, defaults: UserDefaults = .standard) {
        runOnce("maintenance.backfillHumanConfirmed", defaults: defaults) {
            backfillHumanConfirmed(context: context)
        }
        runOnce("maintenance.deleteRunawayCalendarEntries", defaults: defaults) {
            deleteRunawayCalendarEntries(context: context)
        }
    }

    private static func runOnce(_ key: String, defaults: UserDefaults, _ step: () -> Int) {
        guard !defaults.bool(forKey: key) else { return }
        let changed = step()
        defaults.set(true, forKey: key)
        AppLogger.log("persistence", level: .notice, "\(key) changed=\(changed)")
    }

    /// `isHumanConfirmed` arrived after most entries existed and defaulted to false, so
    /// the prompts had no examples at all of how the user classifies work. Entries the
    /// user started by hand, and auto-started ones that carry a project, count as
    /// examples. Calendar entries do not: their labels were never chosen by anyone.
    @discardableResult
    static func backfillHumanConfirmed(context: ModelContext) -> Int {
        let manual = EntrySource.manual.rawValue
        let ai = EntrySource.aiAutoStart.rawValue
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> {
                $0.endAt != nil && $0.isHumanConfirmed == false
                    && ($0.sourceRaw == manual || $0.sourceRaw == ai)
            }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var changed = 0
        for entry in rows where entry.source == .manual || entry.project != nil {
            entry.isHumanConfirmed = true
            changed += 1
        }
        try? context.save()
        return changed
    }

    /// The old calendar scheduler resolved recurring events to their first occurrence,
    /// so a single "Paternity leave" series produced hundreds of entries thousands of
    /// hours long. No real calendar-started entry lasts more than 12 hours.
    @discardableResult
    static func deleteRunawayCalendarEntries(context: ModelContext, maxHours: Double = 12) -> Int {
        let calendar = EntrySource.calendar.rawValue
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endAt != nil && $0.sourceRaw == calendar }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        let runaway = rows.filter { ($0.duration ?? 0) > maxHours * 3600 }
        for entry in runaway { context.delete(entry) }
        try? context.save()
        return runaway.count
    }
}
