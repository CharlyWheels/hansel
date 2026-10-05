import Foundation
import SwiftData
import Observation

/// Watches a running `TimeEntry` for signals that the task is probably done, so the user
/// can be asked. It never ends an entry by itself: the user always stops the timer.
///
/// Triggers:
///   1. **Away on return** — on the idle → active transition, if the user was away
///      ≥ `promptIdleMinutes` while an entry ran, ask whether to keep that time, drop
///      it from the entry, or end the entry where the absence began.
///   2. **Activity drift** — every tick, compare `RuleEngine.evaluate()` on the last 15 min
///      of activity samples against the running entry. If the inferred classification
///      differs, across two consecutive checks, surface the prompt.
///   3. **Periodic check-in** — entry running longer than `periodicCheckMinutes` and no
///      prompt has been shown recently.
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
        /// "You were away N min while '{title}' ran." → [Keep] / [Remove] / [End at start]
        case awayQuestion(from: Date, to: Date)
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
    /// A call heard through the microphone is work even without keyboard input, so
    /// returning from a "quiet" meeting does not ask about away time.
    weak var meetingDetector: MeetingDetector?
    private let modelContext: ModelContext

    // Internal state
    private var tickTimer: Timer?
    private var idleStartedAt: Date?
    /// Whether a meeting was in progress at any point during the current idle span.
    private var meetingDuringIdle = false
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

    /// Drops the away span from the running entry and carries on tracking.
    func excludeAwayTime() {
        guard let prompt = takePromptForRunningEntry(),
              case let .awayQuestion(from, to) = prompt.kind else { return }
        timerController?.excludeAwayTime(from: from, to: to)
        AppLogger.log("timer", level: .info, "completion_away_excluded id=\(prompt.entryId)")
    }

    /// Ends the running entry where the absence began.
    func endAtAwayStart() {
        guard let prompt = takePromptForRunningEntry(),
              case let .awayQuestion(from, _) = prompt.kind else { return }
        timerController?.stop(at: from)
        AppLogger.log("timer", level: .info, "completion_away_end id=\(prompt.entryId)")
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
            meetingDuringIdle = meetingDetector?.state.isInMeeting == true
        } else {
            evaluateReturnFromIdle()
            idleStartedAt = nil
            meetingDuringIdle = false
        }
    }

    /// Called periodically while idle so a meeting that starts mid-absence counts.
    private func noteMeetingWhileIdle() {
        if idleStartedAt != nil, meetingDetector?.state.isInMeeting == true {
            meetingDuringIdle = true
        }
    }

    private func evaluateReturnFromIdle() {
        guard let idleStart = idleStartedAt else { return }
        guard let controller = timerController, controller.isRunning,
              let entry = controller.runningEntry else { return }
        if meetingDuringIdle || meetingDetector?.state.isInMeeting == true {
            AppLogger.log("timer", level: .info, "completion_away_skipped reason=meeting")
            return
        }
        let now = Date()
        // Only the part of the absence that overlaps the entry matters.
        let awayStart = max(idleStart, entry.startAt)
        let awaySeconds = now.timeIntervalSince(awayStart)
        guard awaySeconds >= TimeInterval(promptIdleMinutes) * 60 else { return }
        let title = entry.title.isEmpty ? "(untitled)" : entry.title
        pendingPrompt = PendingPrompt(
            kind: .awayQuestion(from: awayStart, to: now),
            message: "You were away \(DurationFormat.hoursMinutes(awaySeconds)) while '\(title)' was running.",
            entryId: entry.id
        )
        AppLogger.log("timer", level: .info, "completion_away_prompt seconds=\(Int(awaySeconds))")
    }

    // MARK: - Tick (drift + periodic)

    private func tick() {
        guard let controller = timerController, controller.isRunning,
              let entry = controller.runningEntry else {
            driftStreak = 0
            return
        }
        if idleMonitor?.isIdle == true {
            noteMeetingWhileIdle()
            return
        }
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
