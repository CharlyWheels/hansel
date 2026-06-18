import Foundation
import SwiftData
import Observation

/// Watches a running `TimeEntry` for signals that the task is probably done, so the user
/// can be prompted or the entry auto-ended.
///
/// Triggers:
///   1. **Auto-end on prolonged idle** — no prompt. Fires when the user has been idle for
///      ≥ `autoEndIdleMinutes`. `endAt` is set to the moment idle started.
///   2. **Short idle on return** — on the idle → active transition, if the user was idle
///      ≥ `promptIdleMinutes` but < `autoEndIdleMinutes`, surface a "Still working on X?"
///      prompt.
///   3. **Activity drift** — every tick, compare `RuleEngine.evaluate()` on the last 15 min
///      of activity samples against the running entry. If the inferred classification
///      differs, across two consecutive checks, surface the prompt.
///   4. **Periodic check-in** — entry running longer than `periodicCheckMinutes` and no
///      prompt has been shown recently.
///
/// UI reads `pendingPrompt` and calls `confirmContinue()`, `confirmEnd()`, or
/// `dismissNotice()`. All thresholds come from `UserDefaults` so Settings edits take
/// effect on the next tick without a restart.
@Observable
@MainActor
final class EntryCompletionService {
    // Public UI state
    enum PendingPromptKind: Equatable {
        case doneQuestion    // "Still working on '{title}'?"  → [Keep] / [End]
        case autoEndNotice   // "Ended '{title}' after N min idle."  → [Dismiss]
    }
    struct PendingPrompt: Equatable {
        let kind: PendingPromptKind
        let message: String
        let entryId: UUID
    }
    private(set) var pendingPrompt: PendingPrompt?

    // Dependencies
    private weak var timerController: TimerController?
    private weak var idleMonitor: IdleMonitor?
    private let modelContext: ModelContext

    // Internal state
    private var tickTimer: Timer?
    private var idleStartedAt: Date?
    /// Task that fires after `autoEndIdleMinutes` if the user is still idle when it runs.
    private var pendingAutoEnd: Task<Void, Never>?
    /// Per-entry cooldown after a prompt is resolved. Keyed by the entry's id so a
    /// freshly started entry can prompt again without waiting for the previous entry's
    /// cooldown to expire.
    private var lastPrompt: (entryId: UUID, at: Date)?
    private let cooldown: TimeInterval = 30 * 60
    /// Drift confirmation: drift must be detected across two consecutive 5-min checks.
    private var lastDriftCheckAt: Date = .distantPast
    private var driftStreak: Int = 0

    init(
        timerController: TimerController,
        idleMonitor: IdleMonitor,
        modelContext: ModelContext
    ) {
        self.timerController = timerController
        self.idleMonitor = idleMonitor
        self.modelContext = modelContext
    }

    func start() {
        stop()
        idleMonitor?.onTransition { [weak self] isIdle in
            Task { @MainActor in self?.handleIdleTransition(isIdle: isIdle) }
        }
        // If we boot while idle, don't immediately auto-end — leave `idleStartedAt` nil so
        // only a fresh transition arms the timer.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        AppLogger.timer.info("EntryCompletionService started")
        AppLogger.log("timer", level: .info, "completion_started")
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        pendingAutoEnd?.cancel()
        pendingAutoEnd = nil
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
        if let prompt = pendingPrompt {
            lastPrompt = (prompt.entryId, Date())
        }
        pendingPrompt = nil
        timerController?.stop()
        AppLogger.log("timer", level: .info, "completion_prompt_end")
    }

    func dismissNotice() {
        pendingPrompt = nil
    }

    // MARK: - Thresholds (from UserDefaults, live-reloaded)

    private var autoEndIdleMinutes: Int {
        max(1, UserDefaults.standard.object(forKey: "autoEndIdleMinutes") as? Int ?? 5)
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
            idleStartedAt = Date()
            armAutoEnd()
        } else {
            pendingAutoEnd?.cancel()
            pendingAutoEnd = nil
            evaluateReturnFromIdle()
            idleStartedAt = nil
        }
    }

    private func armAutoEnd() {
        pendingAutoEnd?.cancel()
        let minutes = autoEndIdleMinutes
        let idleStart = idleStartedAt ?? Date()
        pendingAutoEnd = Task { [weak self] in
            // Sleep for the threshold. If user comes back first, transition handler
            // cancels this task before it fires.
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.fireAutoEnd(idleStart: idleStart, afterMinutes: minutes)
            }
        }
    }

    private func fireAutoEnd(idleStart: Date, afterMinutes: Int) {
        guard idleMonitor?.isIdle == true else { return }
        guard let controller = timerController, controller.isRunning,
              let entry = controller.runningEntry else { return }
        let title = entry.title.isEmpty ? "(untitled)" : entry.title
        let entryId = entry.id
        controller.stop(at: idleStart)
        pendingPrompt = PendingPrompt(
            kind: .autoEndNotice,
            message: "Ended '\(title)' after \(afterMinutes) min idle.",
            entryId: entryId
        )
        AppLogger.timer.info("Auto-ended entry after \(afterMinutes, privacy: .public) min idle")
        AppLogger.log("timer", level: .info, "completion_auto_end title=\(title) minutes=\(afterMinutes)")
    }

    private func evaluateReturnFromIdle() {
        guard let idleStart = idleStartedAt else { return }
        guard let controller = timerController, controller.isRunning,
              let entry = controller.runningEntry else { return }
        let idleSeconds = Date().timeIntervalSince(idleStart)
        let promptMin = TimeInterval(promptIdleMinutes) * 60
        let autoEndMin = TimeInterval(autoEndIdleMinutes) * 60
        guard idleSeconds >= promptMin && idleSeconds < autoEndMin else { return }
        guard isCooldownPassed(for: entry) else { return }
        raiseDoneQuestion(for: entry, reason: "short_idle")
    }

    // MARK: - Tick (drift + periodic)

    private func tick() {
        guard let controller = timerController, controller.isRunning,
              let entry = controller.runningEntry else {
            driftStreak = 0
            return
        }
        if idleMonitor?.isIdle == true { return }
        guard pendingPrompt == nil else { return }
        guard isCooldownPassed(for: entry) else { return }

        // Periodic check-in: simplest check first.
        let runningFor = Date().timeIntervalSince(entry.startAt)
        let periodicThreshold = TimeInterval(periodicCheckMinutes) * 60
        if runningFor >= periodicThreshold {
            raiseDoneQuestion(for: entry, reason: "periodic")
            return
        }

        // Drift check — only every 5 min, and only after the entry has run long enough
        // for drift to be meaningful.
        if runningFor >= 15 * 60 {
            evaluateDrift(for: entry)
        }
    }

    private func evaluateDrift(for entry: TimeEntry) {
        let now = Date()
        guard now.timeIntervalSince(lastDriftCheckAt) >= 5 * 60 else { return }
        lastDriftCheckAt = now

        let windowStart = now.addingTimeInterval(-15 * 60)
        let samples = fetchRecentSamples(from: windowStart, to: now)
        let rules = fetchRules()
        let hints = RuleEngine.evaluate(rules: rules, samples: samples)
        if driftPresent(hints: hints, entry: entry) {
            driftStreak += 1
            AppLogger.log("timer", level: .debug, "completion_drift streak=\(driftStreak)")
            if driftStreak >= 2 {
                driftStreak = 0
                raiseDoneQuestion(for: entry, reason: "drift")
            }
        } else {
            driftStreak = 0
        }
    }

    /// "Drift" = the rule engine confidently (non-nil) infers a different
    /// role/project/customer than the running entry has. If rules produce no signal we
    /// don't treat that as drift.
    private func driftPresent(hints: RuleEngine.Hints, entry: TimeEntry) -> Bool {
        if hints.isEmpty { return false }
        if let h = hints.role, h.id != entry.role?.id { return true }
        if let h = hints.project, h.id != entry.project?.id { return true }
        if let h = hints.customer, h.id != entry.customer?.id { return true }
        return false
    }

    private func fetchRecentSamples(from: Date, to: Date) -> [ActivitySample] {
        let descriptor = FetchDescriptor<ActivitySample>(
            predicate: #Predicate<ActivitySample> { $0.timestamp >= from && $0.timestamp < to },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchRules() -> [ClassificationRule] {
        (try? modelContext.fetch(FetchDescriptor<ClassificationRule>())) ?? []
    }

    // MARK: - Helpers

    private func raiseDoneQuestion(for entry: TimeEntry, reason: String) {
        let title = entry.title.isEmpty ? "(untitled)" : entry.title
        pendingPrompt = PendingPrompt(
            kind: .doneQuestion,
            message: "Still working on '\(title)'?",
            entryId: entry.id
        )
        AppLogger.log("timer", level: .info, "completion_prompt reason=\(reason) title=\(title)")
    }

    private func isCooldownPassed(for entry: TimeEntry) -> Bool {
        guard let last = lastPrompt else { return true }
        // Different entry → no cooldown; a fresh entry always gets fresh prompts.
        if last.entryId != entry.id { return true }
        return Date().timeIntervalSince(last.at) >= cooldown
    }
}
