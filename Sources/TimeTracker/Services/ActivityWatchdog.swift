import Foundation

/// Polls every 30 s. If no timer is running and the system has been active for
/// ≥ `autoStartActivityMinutes` (default 10), asks the AI to draft an entry and
/// auto-starts the timer. Idle periods reset the window.
@MainActor
final class ActivityWatchdog {
    private weak var timerController: TimerController?
    private weak var idleMonitor: IdleMonitor?
    private let suggestionEngine: SuggestionEngine

    private var windowStart: Date?
    private var pollTimer: Timer?
    private var pendingDraft: Task<Void, Never>?

    init(
        timerController: TimerController,
        idleMonitor: IdleMonitor,
        suggestionEngine: SuggestionEngine
    ) {
        self.timerController = timerController
        self.idleMonitor = idleMonitor
        self.suggestionEngine = suggestionEngine
    }

    func start() {
        idleMonitor?.onTransition { [weak self] isIdle in
            Task { @MainActor in
                self?.windowStart = isIdle ? nil : Date()
            }
        }
        windowStart = (idleMonitor?.isIdle == true) ? nil : Date()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        AppLogger.timer.info("ActivityWatchdog started")
        AppLogger.log("timer", level: .info, "watchdog_started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingDraft?.cancel()
        pendingDraft = nil
    }

    private func tick() {
        guard let controller = timerController else { return }
        if controller.isRunning {
            windowStart = nil
            return
        }
        if idleMonitor?.isIdle == true {
            windowStart = nil
            return
        }
        if windowStart == nil {
            windowStart = Date()
            return
        }
        let minutes = UserDefaults.standard.object(forKey: "autoStartActivityMinutes") as? Int ?? 10
        let threshold = TimeInterval(max(1, minutes)) * 60
        guard let start = windowStart, Date().timeIntervalSince(start) >= threshold else { return }
        windowStart = nil  // prevent retrigger; reset on next tick if still active
        scheduleDraft(from: start)
    }

    private func scheduleDraft(from: Date) {
        pendingDraft?.cancel()
        pendingDraft = Task { [weak self] in
            guard let self else { return }
            await self.triggerDraft(from: from)
        }
    }

    private func triggerDraft(from: Date) async {
        guard let controller = timerController, !controller.isRunning else { return }
        do {
            let draft = try await suggestionEngine.draft(from: from, to: Date())
            guard !controller.isRunning else { return }
            controller.startFromAI(
                title: draft.title,
                startAt: from,
                role: draft.role,
                project: draft.project,
                customer: draft.customer
            )
            AppLogger.timer.info("Watchdog auto-started timer: \(draft.title, privacy: .public)")
            AppLogger.log("timer", level: .info, "watchdog_autostart title=\(draft.title)")
        } catch {
            AppLogger.ai.error("Watchdog draft failed: \(error.localizedDescription, privacy: .public)")
            AppLogger.log("ai", level: .error, "watchdog_draft_failed: \(error.localizedDescription)")
        }
    }
}
