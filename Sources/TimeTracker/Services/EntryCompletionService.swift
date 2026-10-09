import Foundation
import SwiftData
import Observation

/// Watches a running `TimeEntry` for signals that the task is probably done, so the user
/// can be asked. It never ends an entry by itself: the user always stops the timer.
///
/// Triggers:
///   1. **Away on return** — time away from the Mac is not tracked. On the idle →
///      active transition, if the user was away ≥ `promptIdleMinutes` while an entry
///      ran, the away span is removed: a short absence splits the entry and the task
///      carries on; a long one (≥ `longAwayMinutes`, e.g. overnight) closes the entry
///      where the absence began. After a lock or sleep that happens by itself, with a
///      notice offering "Keep that time". With the screen unlocked throughout it is
///      only asked: reading without touching the keyboard is work, and cutting it out
///      on its own chopped an afternoon into a dozen entries. Only a real call with the
///      screen unlocked throughout counts as present without asking.
///   2. **Periodic check-in** — entry running longer than `periodicCheckMinutes` and no
///      prompt has been shown recently. Since the timer never stops by itself, this is
///      what catches one left running by mistake.
///
/// Task *changes* are the `FocusArbiter`'s job. This service used to run its own
/// rule-based "drift" check as well, which put a second, competing question on screen.
///
/// UI reads `pendingPrompt` and calls `confirmContinue()`, `confirmEnd()`,
/// `excludeAwayTime()` or `endAtAwayStart()`. Every answer is checked against the entry
/// the question was about, so a stale banner can never act on a different entry. All
/// thresholds come from `UserDefaults` so Settings edits take effect on the next tick.
@Observable
@MainActor
final class EntryCompletionService {
    // Public UI state
    enum PendingPromptKind: Equatable {
        case doneQuestion    // "Still working on '{title}'?"  → [Keep] / [End]
    }
    struct PendingPrompt: Equatable {
        let kind: PendingPromptKind
        let message: String
        let entryId: UUID
    }
    private(set) var pendingPrompt: PendingPrompt?

    /// What was done about an absence, so it can be shown and undone.
    struct AwayNotice: Equatable {
        enum Action: Equatable {
            case split(originalID: UUID, continuationID: UUID)
            case trimmedStart(entryID: UUID, originalStart: Date)
            case stopped(entryID: UUID)
            /// Nothing done yet: the screen stayed unlocked, so the user is asked.
            case question(entryID: UUID)
        }
        let action: Action
        let message: String
        let from: Date
        let to: Date
        let at: Date
        var isQuestion: Bool {
            if case .question = action { return true }
            return false
        }
    }
    private(set) var awayNotice: AwayNotice?

    // Dependencies
    private weak var timerController: TimerController?
    private weak var idleMonitor: IdleMonitor?
    /// A call heard through the microphone is work even without keyboard input, so
    /// returning from a "quiet" meeting does not ask about away time.
    weak var meetingDetector: MeetingDetector?
    private let modelContext: ModelContext

    // Internal state
    private var tickTimer: Timer?
    private var idleStartedAt: Date?
    /// Whether a call was in progress when the current idle span began.
    private var inCallWhenIdleBegan = false
    /// Per-entry cooldown after a prompt is resolved. Keyed by the entry's id so a
    /// freshly started entry can prompt again without waiting for the previous entry's
    /// cooldown to expire.
    private var lastPrompt: (entryId: UUID, at: Date)?
    private let cooldown: TimeInterval = 30 * 60

    init(
        timerController: TimerController,
        idleMonitor: IdleMonitor,
        modelContext: ModelContext
    ) {
        self.timerController = timerController
        self.idleMonitor = idleMonitor
        self.modelContext = modelContext
        timerController.onRunningEntryChange { [weak self] id in
            // A question about an entry that is no longer running is meaningless.
            guard let self, let prompt = self.pendingPrompt, prompt.entryId != id else { return }
            self.pendingPrompt = nil
        }
    }

    func start() {
        stop()
        idleMonitor?.onTransition { [weak self] isIdle in
            Task { @MainActor in self?.handleIdleTransition(isIdle: isIdle) }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        AppLogger.timer.info("EntryCompletionService started")
        AppLogger.log("timer", level: .info, "completion_started")
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - UI intents

    func confirmContinue() {
        if let prompt = pendingPrompt {
            lastPrompt = (prompt.entryId, Date())
        }
        pendingPrompt = nil
        AppLogger.log("timer", level: .info, "completion_prompt_continue")
    }

    func confirmEnd() {
        guard let prompt = takePromptForRunningEntry() else { return }
        timerController?.stop()
        AppLogger.log("timer", level: .info, "completion_prompt_end id=\(prompt.entryId)")
    }

    /// "Keep that time": puts the away span back into the entry.
    func keepAwayTime() {
        guard let notice = awayNotice, let controller = timerController else { return }
        awayNotice = nil
        switch notice.action {
        case let .split(originalID, continuationID):
            guard let original = fetchEntry(originalID), let continuation = fetchEntry(continuationID),
                  controller.undoSwitch(previous: original, created: continuation) else { return }
        case let .trimmedStart(entryID, originalStart):
            guard let entry = fetchEntry(entryID) else { return }
            entry.startAt = originalStart
            try? modelContext.save()
        case let .stopped(entryID):
            // Only if nothing else has started since.
            guard !controller.isRunning, let entry = fetchEntry(entryID) else { return }
            controller.resume(entry)
        case .question:
            // Nothing was removed; the time is already in the entry.
            break
        }
        AppLogger.log("timer", level: .info, "completion_away_kept")
    }

    /// "I was away" on the question: cuts the span out and the task carries on. Never
    /// closes the entry, even after a long absence: the answer may come well after the
    /// return, and closing where the absence began would drop the work done since.
    func removeAskedAwayTime() {
        guard let notice = awayNotice, case let .question(entryID) = notice.action,
              let controller = timerController, let entry = controller.runningEntry,
              entry.id == entryID else {
            awayNotice = nil
            return
        }
        awayNotice = nil
        removeAway(from: notice.from, to: notice.to, of: entry, stop: false)
    }

    func dismissAwayNotice() {
        awayNotice = nil
    }

    /// Whether "Keep that time" can still be applied.
    var canKeepAwayTime: Bool {
        guard let notice = awayNotice, let controller = timerController else { return false }
        switch notice.action {
        case let .split(_, continuationID): return controller.runningEntry?.id == continuationID
        case let .trimmedStart(entryID, _): return fetchEntry(entryID) != nil
        case .stopped: return !controller.isRunning
        case .question: return false
        }
    }

    private func fetchEntry(_ id: UUID) -> TimeEntry? {
        try? modelContext.fetch(FetchDescriptor<TimeEntry>(predicate: #Predicate<TimeEntry> { $0.id == id })).first
    }

    /// Clears the pending prompt and returns it only if it is still about the running
    /// entry; a stale answer is discarded rather than applied to whatever runs now.
    private func takePromptForRunningEntry() -> PendingPrompt? {
        guard let prompt = pendingPrompt else { return nil }
        pendingPrompt = nil
        lastPrompt = (prompt.entryId, Date())
        guard let running = timerController?.runningEntry, running.id == prompt.entryId else {
            AppLogger.log("timer", level: .info, "completion_prompt_stale id=\(prompt.entryId)")
            return nil
        }
        return prompt
    }

    // MARK: - Thresholds (from UserDefaults, live-reloaded)
    /// An absence at least this long closes the entry instead of splitting it: nobody
    /// wants yesterday's task to carry on by itself in the morning.
    private var longAwayMinutes: Int {
        max(5, UserDefaults.standard.object(forKey: "longAwayMinutes") as? Int ?? 60)
    }
    private var promptIdleMinutes: Int {
        max(1, UserDefaults.standard.object(forKey: "promptIdleMinutes") as? Int ?? 2)
    }
    private var periodicCheckMinutes: Int {
        max(5, UserDefaults.standard.object(forKey: "periodicCheckMinutes") as? Int ?? 90)
    }

    // MARK: - Idle transitions

    private func handleIdleTransition(isIdle: Bool) {
        if isIdle {
            idleStartedAt = idleMonitor?.currentIdleStart ?? Date()
            inCallWhenIdleBegan = meetingDetector?.state.isInMeeting == true
        } else {
            evaluateReturnFromIdle()
            idleStartedAt = nil
            inCallWhenIdleBegan = false
        }
    }

    private func evaluateReturnFromIdle() {
        guard let idleStart = idleStartedAt else { return }
        guard let controller = timerController, controller.isRunning,
              let entry = controller.runningEntry else { return }
        let now = Date()
        // Only the part of the absence that overlaps the entry matters.
        let awayStart = max(idleStart, entry.startAt)
        let awaySeconds = now.timeIntervalSince(awayStart)
        let decision = Self.awayDecision(
            awaySeconds: awaySeconds,
            sawLockOrSleep: idleMonitor?.currentIdleSawLockOrSleep ?? true,
            inCallWhenIdleBegan: inCallWhenIdleBegan,
            inCallNow: meetingDetector?.state.isInMeeting == true,
            minAwaySeconds: TimeInterval(promptIdleMinutes) * 60,
            longAwaySeconds: TimeInterval(longAwayMinutes) * 60
        )
        if decision == .presentOnCall {
            AppLogger.log("timer", level: .info, "completion_away_skipped reason=call")
        }
        let title = entry.title.isEmpty ? "(untitled)" : entry.title
        if decision == .ask {
            awayNotice = AwayNotice(
                action: .question(entryID: entry.id),
                message: "No keyboard or mouse for \(DurationFormat.hoursMinutes(awaySeconds)) during '\(title)'. Were you away?",
                from: awayStart, to: now, at: now
            )
            AppLogger.log("timer", level: .info, "completion_away_asked seconds=\(Int(awaySeconds))")
            return
        }
        guard decision == .remove || decision == .stop else { return }
        removeAway(from: awayStart, to: now, of: entry, stop: decision == .stop)
    }

    /// Takes `from..<to` out of the running entry and says so in a notice that can undo it.
    private func removeAway(from awayStart: Date, to now: Date, of entry: TimeEntry, stop: Bool) {
        guard let controller = timerController else { return }
        let title = entry.title.isEmpty ? "(untitled)" : entry.title
        let awaySeconds = now.timeIntervalSince(awayStart)
        let away = DurationFormat.hoursMinutes(awaySeconds)

        let action: AwayNotice.Action
        let message: String
        if stop {
            let entryID = entry.id
            controller.stop(at: awayStart)
            action = .stopped(entryID: entryID)
            message = "Stopped '\(title)' when you left — you were away \(away)."
        } else {
            switch controller.excludeAwayTime(from: awayStart, to: now) {
            case let .split(originalID, continuationID)?:
                action = .split(originalID: originalID, continuationID: continuationID)
            case let .trimmedStart(entryID, originalStart)?:
                action = .trimmedStart(entryID: entryID, originalStart: originalStart)
            case nil:
                return
            }
            message = "Removed \(away) away from '\(title)'."
        }
        awayNotice = AwayNotice(action: action, message: message, from: awayStart, to: now, at: now)
        AppLogger.log("timer", level: .info, "completion_away_removed seconds=\(Int(awaySeconds)) stopped=\(stop)")
    }

    enum AwayDecision: Equatable {
        /// Too short to matter.
        case ignore
        /// Listening on a call: present, not away.
        case presentOnCall
        /// Drop the away span and carry on with the task.
        case remove
        /// Close the entry where the absence began.
        case stop
        /// No input but the screen stayed unlocked: maybe reading. Ask, change nothing.
        case ask
    }

    /// Listening on a call without touching the keyboard is still work — but only with
    /// the screen unlocked, and with the call there both when the quiet began and on
    /// return. A lock or sleep always means the user was away; without one it is only
    /// a question.
    static func awayDecision(
        awaySeconds: TimeInterval,
        sawLockOrSleep: Bool,
        inCallWhenIdleBegan: Bool,
        inCallNow: Bool,
        minAwaySeconds: TimeInterval,
        longAwaySeconds: TimeInterval
    ) -> AwayDecision {
        if !sawLockOrSleep && inCallWhenIdleBegan && inCallNow { return .presentOnCall }
        if awaySeconds < minAwaySeconds { return .ignore }
        if !sawLockOrSleep { return .ask }
        return awaySeconds >= longAwaySeconds ? .stop : .remove
    }

    // MARK: - Tick (drift + periodic)

    private func tick() {
        guard let controller = timerController, controller.isRunning,
              let entry = controller.runningEntry else { return }
        if idleMonitor?.isIdle == true { return }
        guard pendingPrompt == nil else { return }
        guard isCooldownPassed(for: entry) else { return }

        // Periodic check-in.
        let runningFor = Date().timeIntervalSince(entry.startAt)
        let periodicThreshold = TimeInterval(periodicCheckMinutes) * 60
        if runningFor >= periodicThreshold {
            raiseDoneQuestion(for: entry, reason: "periodic")
        }
    }

    // MARK: - Helpers

    private func raiseDoneQuestion(for entry: TimeEntry, reason: String) {
        let title = entry.title.isEmpty ? "(untitled)" : entry.title
        pendingPrompt = PendingPrompt(
            kind: .doneQuestion,
            message: "Still working on '\(title)'?",
            entryId: entry.id
        )
        AppLogger.log("timer", level: .info, "completion_prompt reason=\(reason)")
    }

    private func isCooldownPassed(for entry: TimeEntry) -> Bool {
        guard let last = lastPrompt else { return true }
        // Different entry → no cooldown; a fresh entry always gets fresh prompts.
        if last.entryId != entry.id { return true }
        return Date().timeIntervalSince(last.at) >= cooldown
    }
}
