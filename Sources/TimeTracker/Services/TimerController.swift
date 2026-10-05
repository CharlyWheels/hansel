import Foundation
import SwiftData
import Observation

enum TimerMachineState: Equatable {
    case watching
    case running
    case confirming
}

/// Single source of truth for "is a timer running".
///
/// Running entries are now persistent `TimeEntry` records with `endAt == nil`, so the
/// Timeline and other views can observe them immediately (via a @Query filter).
/// Stop sets `endAt = Date()` and marks the entry confirmed. Cancel deletes the entry.
@Observable
@MainActor
final class TimerController {
    private(set) var state: TimerMachineState = .watching
    private(set) var runningEntry: TimeEntry?

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // On launch, recover any in-progress entry (endAt == nil) so a crash or restart
        // doesn't orphan a running timer.
        recoverRunningEntry()
    }

    var isRunning: Bool { state == .running }

    var elapsed: TimeInterval {
        guard let entry = runningEntry else { return 0 }
        return Date().timeIntervalSince(entry.startAt)
    }

    // MARK: - Start methods

    func startManual(
        title: String = "",
        role: Role? = nil,
        project: Project? = nil,
        customer: Customer? = nil
    ) {
        start(
            title: title, startAt: Date(),
            role: role, project: project, customer: customer,
            source: .manual
        )
    }

    /// Calendar-driven auto-start. `startAt` is the event's scheduled start so
    /// returning-from-idle can backfill.
    func startFromCalendar(
        title: String,
        startAt: Date,
        role: Role? = nil,
        project: Project? = nil,
        customer: Customer? = nil,
        eventIdentifier: String
    ) {
        start(
            title: title, startAt: startAt,
            role: role, project: project, customer: customer,
            source: .calendar
        )
    }

    /// AI-driven auto-start after 10 min of continuous activity.
    func startFromAI(
        title: String,
        startAt: Date = Date(),
        role: Role? = nil,
        project: Project? = nil,
        customer: Customer? = nil,
        todo: Todo? = nil
    ) {
        start(
            title: title, startAt: startAt,
            role: role, project: project, customer: customer,
            source: .aiAutoStart, todo: todo
        )
    }

    private func start(
        title: String,
        startAt: Date,
        role: Role?,
        project: Project?,
        customer: Customer?,
        source: EntrySource,
        todo: Todo? = nil
    ) {
        guard state == .watching else {
            AppLogger.timer.warning("start ignored — state=\(String(describing: self.state), privacy: .public)")
            AppLogger.log("timer", level: .warning, "start ignored state=\(state)")
            return
        }
        let entry = TimeEntry(
            title: title,
            startAt: startAt,
            endAt: nil,
            role: role,
            project: project,
            customer: customer,
            isConfirmed: false,
            source: source,
            billableCached: BillableResolver.resolve(role: role, project: project, customer: customer),
            linkedTodo: todo
        )
        modelContext.insert(entry)
        try? modelContext.save()
        runningEntry = entry
        state = .running
        AppLogger.timer.info("Timer started source=\(source.rawValue, privacy: .public) title=\(title, privacy: .public)")
        AppLogger.log("timer", level: .info, "start source=\(source.rawValue) title=\(title)")
    }

    // MARK: - Stop / cancel

    @discardableResult
    func stop() -> TimeEntry? {
        stop(at: Date())
    }

    /// Stop the running entry setting `endAt` to a supplied date. The supplied date is
    /// clamped to be `>= startAt` so we never produce a negative-duration entry.
    @discardableResult
    func stop(at endDate: Date) -> TimeEntry? {
        guard state == .running, let entry = runningEntry else {
            AppLogger.timer.warning("stop called while not running")
            return nil
        }
        let clamped = max(endDate, entry.startAt)
        entry.endAt = clamped
        if entry.title.isEmpty { entry.title = "(untitled)" }
        entry.isConfirmed = true
        // `isHumanConfirmed` is NOT set here for auto-created entries. Closing an entry
        // is not the same as a human vouching for it: an AI- or calendar-started entry
        // that simply ran to completion is a guess, not evidence. Only a manual start
        // (the user pressed Start and typed the title) or an explicit edit counts.
        // Without this distinction the classification prompt is fed its own output.
        if entry.source == .manual { entry.isHumanConfirmed = true }
        entry.refreshBillableCache()
        do {
            try modelContext.save()
            let dur = entry.duration ?? 0
            AppLogger.timer.info("Timer stopped — duration=\(Int(dur))s id=\(entry.id.uuidString, privacy: .public)")
            AppLogger.log("timer", level: .info, "stop id=\(entry.id) duration=\(Int(dur))s billable=\(entry.billableCached) endAt=\(clamped.timeIntervalSince1970)")
        } catch {
            AppLogger.timer.error("Save failed: \(error.localizedDescription, privacy: .public)")
            AppLogger.log("timer", level: .error, "save_failed: \(error.localizedDescription)")
        }
        let saved = entry
        runningEntry = nil
        state = .watching
        return saved
    }

    func cancel() {
        guard state == .running, let entry = runningEntry else { return }
        AppLogger.timer.notice("Timer cancelled without saving")
        AppLogger.log("timer", level: .notice, "cancel")
        modelContext.delete(entry)
        try? modelContext.save()
        runningEntry = nil
        state = .watching
    }

    // MARK: - Recovery

    private func recoverRunningEntry() {
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endAt == nil }
        )
        guard let entries = try? modelContext.fetch(descriptor), let entry = entries.first else { return }
        // If somehow there are multiples, keep the most recent and close the rest.
        for stray in entries where stray.id != entry.id {
            stray.endAt = stray.startAt.addingTimeInterval(60)
            stray.isConfirmed = false
        }
        try? modelContext.save()
        runningEntry = entry
        state = .running
        AppLogger.timer.info("Recovered running entry \(entry.id.uuidString, privacy: .public)")
        AppLogger.log("timer", level: .info, "recovered id=\(entry.id)")
    }
}
