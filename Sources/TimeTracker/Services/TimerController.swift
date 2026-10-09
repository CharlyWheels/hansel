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
    private(set) var runningEntry: TimeEntry? {
        didSet {
            guard oldValue?.id != runningEntry?.id else { return }
            let id = runningEntry?.id
            for listener in runningEntryListeners { listener(id) }
        }
    }
    /// Notified whenever the running entry changes identity (start, stop, switch,
    /// cancel), so anything holding a question about the old entry can drop it.
    private var runningEntryListeners: [(UUID?) -> Void] = []

    func onRunningEntryChange(_ listener: @escaping (UUID?) -> Void) {
        runningEntryListeners.append(listener)
    }
    /// When the user last edited the running entry by hand. The arbiter will not
    /// propose over a recent human decision.
    private(set) var lastManualEditAt: Date?

    /// Called by the editing surfaces whenever the user changes an entry themselves.
    func noteManualEdit(at date: Date = Date()) {
        lastManualEditAt = date
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // On launch, recover any in-progress entry (endAt == nil) so a crash or restart
        // doesn't orphan a running timer.
        recoverRunningEntry()
    }

    /// `.confirming` means "running, with a boundary proposal awaiting the user", so it
    /// counts as running everywhere: the menu-bar icon stays red, the popover keeps
    /// showing the running section, and nothing may start on top of it.
    var isRunning: Bool { state == .running || state == .confirming }

    var elapsed: TimeInterval {
        guard let entry = runningEntry else { return 0 }
        return Date().timeIntervalSince(entry.startAt)
    }

    // MARK: - Start methods

    func startManual(
        title: String = "",
        role: Role? = nil,
        project: Project? = nil,
        customer: Customer? = nil,
        todo: Todo? = nil
    ) {
        start(
            title: title, startAt: Date(),
            role: role, project: project, customer: customer,
            source: .manual, todo: todo
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
        // No `guard state == .watching` here any more. Silently dropping starts is how
        // the app lost events: a meeting could begin while another task ran and nothing
        // happened at all. Callers that must not clobber a running entry go through
        // `switchTo`. Starting on top of a running entry must still close it, though:
        // replacing `runningEntry` alone would leave an entry open forever.
        if isRunning, let current = runningEntry {
            AppLogger.timer.warning("start called while running — closing the current entry first")
            AppLogger.log("timer", level: .warning, "start_while_running closing=\(current.id)")
            stop(at: max(startAt, current.startAt))
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
        if source == .manual { lastManualEditAt = Date() }
        AppLogger.timer.info("Timer started source=\(source.rawValue, privacy: .public) title=\(title, privacy: .private)")
        AppLogger.log("timer", level: .info, "start source=\(source.rawValue)")
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
        guard isRunning, let entry = runningEntry else {
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
        guard isRunning, let entry = runningEntry else { return }
        AppLogger.timer.notice("Timer cancelled without saving")
        AppLogger.log("timer", level: .notice, "cancel")
        modelContext.delete(entry)
        try? modelContext.save()
        runningEntry = nil
        state = .watching
    }

    // MARK: - Switching

    /// What a new entry should look like. Kept separate from `TimeEntry` so callers can
    /// describe an intent without touching the store.
    struct EntryPlan: Equatable {
        var title: String
        var role: Role?
        var project: Project?
        var customer: Customer?
        var todo: Todo?

        init(
            title: String,
            role: Role? = nil,
            project: Project? = nil,
            customer: Customer? = nil,
            todo: Todo? = nil
        ) {
            self.title = title
            self.role = role
            self.project = project
            self.customer = customer
            self.todo = todo
        }
    }

    enum SwitchOutcome: Equatable {
        case switched(closed: UUID, opened: UUID, at: Date)
        case correctedInPlace(id: UUID)
        case started(id: UUID)
        case rejected(String)
    }

    /// Move to a different task, closing the current entry at `boundaryAt` and opening
    /// the next one at the same instant.
    ///
    /// The boundary is retroactive by design: the user is told about a change some
    /// minutes after it happened, so the previous entry must end when the work actually
    /// stopped, not when the question was answered.
    ///
    /// SwiftData offers no real multi-object transaction, so this does the pair of
    /// mutations under a single `save()` and rolls back to a pre-image on failure
    /// rather than pretending to be atomic.
    @discardableResult
    func switchTo(
        _ plan: EntryPlan,
        boundaryAt: Date,
        source: EntrySource,
        now: Date = Date()
    ) -> SwitchOutcome {
        let current = runningEntry.map {
            TimelineGuard.Segment(id: $0.id, start: $0.startAt, end: $0.endAt)
        }
        let previousEnd = current == nil ? latestEndedAt() : nil
        switch TimelineGuard.plan(
            current: current, boundaryAt: boundaryAt, now: now, previousEnd: previousEnd
        ) {

        case .reject(let reason):
            AppLogger.timer.warning("switch rejected: \(reason, privacy: .public)")
            AppLogger.log("timer", level: .warning, "switch_rejected reason=\(reason)")
            return .rejected(reason)

        case .startFresh(let at):
            start(
                title: plan.title, startAt: at,
                role: plan.role, project: plan.project, customer: plan.customer,
                source: source, todo: plan.todo
            )
            let id = runningEntry?.id ?? UUID()
            AppLogger.log("timer", level: .info, "switch_started id=\(id)")
            return .started(id: id)

        case .correctInPlace:
            guard let entry = runningEntry else { return .rejected("nothing running") }
            apply(plan, to: entry)
            entry.source = source == .aiSwitch ? .aiAutoStart : source
            entry.refreshBillableCache()
            try? modelContext.save()
            AppLogger.timer.info("Corrected running entry in place: \(plan.title, privacy: .private)")
            AppLogger.log("timer", level: .info, "switch_corrected id=\(entry.id)")
            return .correctedInPlace(id: entry.id)

        case let .openNew(closeAt, startAt):
            guard let previous = runningEntry else { return .rejected("nothing running") }
            // Pre-image for restoring on failure. `rollback()` is not an option: the
            // context is shared with the views, and rolling it back would also throw
            // away whatever the user is typing elsewhere.
            let previousEnd = previous.endAt
            let previousConfirmed = previous.isConfirmed
            let previousTitle = previous.title
            let previousBillable = previous.billableCached

            previous.endAt = closeAt
            if previous.title.isEmpty { previous.title = "(untitled)" }
            previous.isConfirmed = true
            previous.refreshBillableCache()

            let next = TimeEntry(
                title: plan.title,
                startAt: startAt,
                endAt: nil,
                role: plan.role,
                project: plan.project,
                customer: plan.customer,
                isConfirmed: false,
                source: source,
                billableCached: BillableResolver.resolve(
                    role: plan.role, project: plan.project, customer: plan.customer
                ),
                linkedTodo: plan.todo
            )
            next.previousEntryID = previous.id
            previous.supersededByID = next.id
            modelContext.insert(next)

            do {
                try modelContext.save()
            } catch {
                modelContext.delete(next)
                previous.endAt = previousEnd
                previous.isConfirmed = previousConfirmed
                previous.title = previousTitle
                previous.billableCached = previousBillable
                previous.supersededByID = nil
                AppLogger.timer.error("Switch save failed: \(error.localizedDescription, privacy: .public)")
                AppLogger.log("timer", level: .error, "switch_save_failed: \(error.localizedDescription)")
                return .rejected("save failed")
            }

            runningEntry = next
            state = .running
            AppLogger.timer.info("Switched to \(plan.title, privacy: .private) at boundary")
            AppLogger.log(
                "timer", level: .info,
                "switch id=\(next.id) from=\(previous.id) at=\(closeAt.timeIntervalSince1970) source=\(source.rawValue)"
            )
            return .switched(closed: previous.id, opened: next.id, at: closeAt)
        }
    }

    /// Re-open a closed entry as the running one.
    func resume(_ entry: TimeEntry) {
        if let current = runningEntry, current.id != entry.id {
            _ = stop(at: Date())
        }
        reopen(entry)
    }

    /// Reverts a switch: removes the entry the switch opened and re-opens the one it
    /// closed. Only valid while the switched-to entry is still the running one —
    /// anything else means the user has moved on and undoing would overwrite their
    /// own later decisions.
    @discardableResult
    func undoSwitch(previous: TimeEntry, created: TimeEntry) -> Bool {
        guard let running = runningEntry, running.id == created.id else {
            AppLogger.log("timer", level: .warning, "undo_rejected created=\(created.id) running=\(runningEntry?.id.uuidString ?? "nil")")
            return false
        }
        // Detach before deleting so nothing ever touches a deleted model.
        runningEntry = nil
        state = .watching
        modelContext.delete(created)
        reopen(previous)
        return true
    }

    private func reopen(_ entry: TimeEntry) {
        entry.endAt = nil
        entry.supersededByID = nil
        entry.isConfirmed = false
        try? modelContext.save()
        runningEntry = entry
        state = .running
        AppLogger.timer.info("Resumed entry \(entry.id.uuidString, privacy: .public)")
        AppLogger.log("timer", level: .info, "resumed id=\(entry.id)")
    }

    /// Removes time the user was away from the running entry, keeping the task going.
    ///
    /// The entry is closed where the absence began and a continuation with the same
    /// labels opens where it ended, so the gap is simply not tracked.
    enum AwayExclusion: Equatable {
        /// The entry began during the absence; its start moved to the return.
        case trimmedStart(entryID: UUID, originalStart: Date)
        /// The entry was closed where the absence began and continued on return.
        case split(originalID: UUID, continuationID: UUID)
    }

    @discardableResult
    func excludeAwayTime(from gapStart: Date, to gapEnd: Date) -> AwayExclusion? {
        guard isRunning, let entry = runningEntry, gapEnd > gapStart else { return nil }
        if gapStart <= entry.startAt {
            let originalStart = entry.startAt
            entry.startAt = min(gapEnd, Date())
            try? modelContext.save()
            AppLogger.log("timer", level: .info, "away_trimmed_start id=\(entry.id)")
            return .trimmedStart(entryID: entry.id, originalStart: originalStart)
        }
        let continuation = TimeEntry(
            title: entry.title,
            startAt: gapEnd,
            endAt: nil,
            role: entry.role,
            project: entry.project,
            customer: entry.customer,
            isConfirmed: false,
            isHumanConfirmed: entry.isHumanConfirmed,
            source: entry.source,
            billableCached: entry.billableCached,
            notes: entry.notes,
            linkedTodo: entry.linkedTodo
        )
        continuation.previousEntryID = entry.id
        stop(at: gapStart)
        entry.supersededByID = continuation.id
        modelContext.insert(continuation)
        try? modelContext.save()
        runningEntry = continuation
        state = .running
        AppLogger.log("timer", level: .info, "away_excluded from=\(entry.id) to=\(continuation.id) gap=\(Int(gapEnd.timeIntervalSince(gapStart)))s")
        return .split(originalID: entry.id, continuationID: continuation.id)
    }

    /// When the most recently closed entry ended.
    func latestEndedAt() -> Date? {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endAt != nil },
            sortBy: [SortDescriptor(\.endAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.endAt
    }

    /// Marks the running entry as awaiting a user decision, so the UI can reflect it
    /// without anything being mutated yet.
    func beginConfirming() {
        guard state == .running else { return }
        state = .confirming
    }

    func endConfirming() {
        guard state == .confirming else { return }
        state = .running
    }

    private func apply(_ plan: EntryPlan, to entry: TimeEntry) {
        entry.title = plan.title
        entry.role = plan.role
        entry.project = plan.project
        entry.customer = plan.customer
        if let todo = plan.todo { entry.linkedTodo = todo }
    }

    // MARK: - Recovery

    private func recoverRunningEntry() {
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endAt == nil },
            sortBy: [SortDescriptor(\.startAt, order: .reverse)]
        )
        guard let entries = try? modelContext.fetch(descriptor), let entry = entries.first else { return }
        // If somehow there are several, keep the most recent running. Each older one
        // ends where the next one began — the latest moment it can have been the task
        // — and is left unconfirmed so it shows up for review instead of losing time.
        if entries.count > 1 {
            AppLogger.log("timer", level: .warning, "recovered_multiple count=\(entries.count)")
            for (index, stray) in entries.enumerated() where index > 0 {
                let next = entries[index - 1]
                stray.endAt = max(stray.startAt, next.startAt)
                stray.isConfirmed = false
            }
        }
        try? modelContext.save()
        runningEntry = entry
        state = .running
        AppLogger.timer.info("Recovered running entry \(entry.id.uuidString, privacy: .public)")
        AppLogger.log("timer", level: .info, "recovered id=\(entry.id)")
    }
}
