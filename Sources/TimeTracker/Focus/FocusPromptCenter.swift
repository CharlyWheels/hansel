import Foundation
import SwiftData
import Observation

/// Holds the one outstanding "did you switch tasks?" question and applies the answer.
///
/// Nothing here mutates the timeline until the user says so — that is the whole point
/// of the ask-first design. The three answers are deliberately distinct:
///
///   - "Same task"        the boundary was wrong
///   - "Switch"           boundary and label both right
///   - "Something else…"  boundary right, label wrong
///
/// Two buttons would conflate the last two and record a false positive as an accepted
/// proposal, poisoning the learning corpus in exactly the way the old `isConfirmed`
/// behaviour did.
@Observable
@MainActor
final class FocusPromptCenter {

    struct PendingSwitch: Identifiable, Equatable {
        let id: UUID
        let decisionID: UUID
        let proposal: FocusPolicy.Proposal
        let previousTitle: String
        /// The entry the question is about. An answer is only applied while this is
        /// still the running entry.
        let fromEntryID: UUID
        let createdAt: Date
        /// The running entry was too young to split, so accepting rewrites it.
        let isCorrection: Bool
        /// The proposed todo, resolved when the question was raised.
        var todoID: UUID? = nil

        var proposedTitle: String { proposal.title ?? "" }
        var hasLabel: Bool { proposal.hasLabel }
    }

    private(set) var pending: PendingSwitch?
    /// Set briefly after an applied switch so the UI can offer an undo.
    private(set) var undoable: UndoRecord?

    struct UndoRecord: Equatable {
        let decisionID: UUID?
        let previousEntryID: UUID
        let newEntryID: UUID
        let appliedAt: Date
        let title: String
    }

    /// A meeting entry closed because its call ended, for the UI to offer "Keep running".
    struct MeetingEndNotice: Equatable {
        let entryID: UUID
        let title: String
        let endedAt: Date
        let appliedAt: Date
    }
    private(set) var meetingEnded: MeetingEndNotice?

    /// An unanswered question must not freeze tracking forever.
    var timeoutMinutes: Int {
        max(1, UserDefaults.standard.object(forKey: "switchPromptTimeoutMinutes") as? Int ?? 10)
    }
    private let undoWindow: TimeInterval = 15 * 60

    private weak var timerController: TimerController?
    private let store: FocusStore
    private let modelContext: ModelContext
    /// Called after any answer so the arbiter can resume.
    var onResolved: (() -> Void)?
    /// Set when the user chooses "it's something else": the entry the split just
    /// opened, for the main window to present in the editor. Cleared by the window.
    var entryToEdit: TimeEntry?

    init(timerController: TimerController, store: FocusStore, modelContext: ModelContext) {
        self.timerController = timerController
        self.store = store
        self.modelContext = modelContext
        timerController.onRunningEntryChange { [weak self] id in
            self?.runningEntryChanged(to: id)
        }
    }

    /// A question or undo about an entry that is no longer running is moot. Leaving it
    /// up would let a late answer split, overwrite or reopen the wrong entry.
    private func runningEntryChanged(to id: UUID?) {
        if let pending, pending.fromEntryID != id {
            resolve(pending, response: .superseded)
            AppLogger.log("timer", level: .info, "switch_prompt_superseded reason=entry_changed")
        }
        if let undoable, undoable.newEntryID != id {
            self.undoable = nil
        }
        if id != nil, let meetingEnded, meetingEnded.entryID != id {
            self.meetingEnded = nil
        }
    }

    private var expiryTimer: Timer?

    func start() {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.expireIfStale()
                self?.expireUndoIfStale()
            }
        }
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    // MARK: - Presenting

    func present(_ action: FocusPolicy.Action, decisionID: UUID, previousTitle: String) {
        // An automatic switch needs nothing running: joining a meeting from idle
        // starts its entry.
        if case let .switchTo(p) = action {
            applyImmediately(p, decisionID: decisionID)
            return
        }
        guard let fromEntryID = timerController?.runningEntry?.id else {
            update(decisionID: decisionID, response: .superseded, toEntryID: nil)
            return
        }
        let proposal: FocusPolicy.Proposal
        let isCorrection: Bool
        switch action {
        case let .ask(p): proposal = p; isCorrection = false
        case let .correctInPlace(p): proposal = p; isCorrection = true
        case .switchTo, .keep: return
        }
        // A newer question replaces an older one. Close the old one in the log, but do
        // not signal `onResolved`: the arbiter is already waiting on the new one.
        if let old = pending {
            update(decisionID: old.decisionID, response: .superseded, toEntryID: nil)
        }
        pending = PendingSwitch(
            id: UUID(),
            decisionID: decisionID,
            proposal: proposal,
            previousTitle: previousTitle,
            fromEntryID: fromEntryID,
            createdAt: Date(),
            isCorrection: isCorrection,
            todoID: store.todoID(forKey: proposal.todo)
        )
        timerController?.beginConfirming()
    }

    /// Expires a stale question, conservatively: the current entry is kept, and the
    /// missed boundary stays in the decision log so the review UI can still offer it.
    func expireIfStale(now: Date = Date()) {
        guard let pending else { return }
        guard now.timeIntervalSince(pending.createdAt) >= TimeInterval(timeoutMinutes) * 60 else { return }
        resolve(pending, response: .timedOut)
        AppLogger.log("timer", level: .info, "switch_prompt_timed_out")
    }

    func expireUndoIfStale(now: Date = Date()) {
        if let undoable, now.timeIntervalSince(undoable.appliedAt) >= undoWindow {
            self.undoable = nil
        }
        if let meetingEnded, now.timeIntervalSince(meetingEnded.appliedAt) >= undoWindow {
            self.meetingEnded = nil
        }
    }

    // MARK: - Meeting end

    /// Closes a meeting's entry where its call ended.
    func stopForMeetingEnd(entryID: UUID, at endedAt: Date) {
        guard let controller = timerController, let entry = controller.runningEntry,
              entry.id == entryID else { return }
        let title = entry.title
        controller.stop(at: endedAt)
        meetingEnded = MeetingEndNotice(entryID: entryID, title: title, endedAt: endedAt, appliedAt: Date())
    }

    /// "Keep running": the meeting was not over after all.
    func keepMeetingRunning() {
        guard let notice = meetingEnded else { return }
        meetingEnded = nil
        if resumeEntry(notice.entryID) {
            AppLogger.log("timer", level: .info, "meeting_end_undone")
        }
    }

    func dismissMeetingEnded() {
        meetingEnded = nil
    }

    /// Re-opens a closed entry, provided nothing else has started since.
    @discardableResult
    func resumeEntry(_ id: UUID) -> Bool {
        guard let controller = timerController, !controller.isRunning else { return false }
        let descriptor = FetchDescriptor<TimeEntry>(predicate: #Predicate<TimeEntry> { $0.id == id })
        guard let entry = try? modelContext.fetch(descriptor).first else { return false }
        meetingEnded = nil
        controller.resume(entry)
        return true
    }

    // MARK: - Answers

    /// "Same task" — the boundary was wrong.
    func keepCurrent() {
        guard let pending else { return }
        resolve(pending, response: .keptCurrent)
    }

    /// "Switch" — boundary and label both right.
    func applySwitch() {
        guard let pending, let controller = timerController else { return }
        let plan = store.plan(from: pending.proposal, todoID: pending.todoID)
        apply(plan, pending: pending, controller: controller, response: .switched)
    }

    /// "Something else…" — the boundary was right but the label was wrong. The split is
    /// applied so no time is misattributed, then the entry is opened for editing.
    func switchAndEdit() {
        guard let pending, let controller = timerController else { return }
        let plan = store.plan(from: pending.proposal, todoID: pending.todoID)
        apply(plan, pending: pending, controller: controller, response: .switchedEdited)
        if let entry = controller.runningEntry { entryToEdit = entry }
    }

    func dismiss() {
        guard let pending else { return }
        resolve(pending, response: .dismissed)
    }

    /// Undo an applied switch: delete the new entry and reopen the previous one.
    func undoLastSwitch() {
        guard let undoable, let controller = timerController else { return }
        // #Predicate cannot reach through a captured struct's property, so hoist the
        // ids into locals first.
        let newEntryID = undoable.newEntryID
        let previousEntryID = undoable.previousEntryID
        let newDescriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.id == newEntryID }
        )
        let previousDescriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.id == previousEntryID }
        )
        self.undoable = nil
        guard let previous = try? modelContext.fetch(previousDescriptor).first,
              let created = try? modelContext.fetch(newDescriptor).first,
              controller.undoSwitch(previous: previous, created: created)
        else {
            AppLogger.log("timer", level: .warning, "switch_undo_refused")
            return
        }
        if let decisionID = undoable.decisionID {
            update(decisionID: decisionID, response: .undone, toEntryID: nil)
        }
        AppLogger.timer.notice("Undid last switch")
        AppLogger.log("timer", level: .notice, "switch_undone")
        onResolved?()
    }

    // MARK: - Internals

    private func apply(
        _ plan: TimerController.EntryPlan,
        pending: PendingSwitch,
        controller: TimerController,
        response: FocusUserResponse
    ) {
        // Clear first: the switch changes the running entry, and the change listener
        // must not mistake our own switch for the entry moving out from under us.
        self.pending = nil
        guard controller.runningEntry?.id == pending.fromEntryID else {
            controller.endConfirming()
            update(decisionID: pending.decisionID, response: .superseded, toEntryID: nil)
            onResolved?()
            return
        }
        controller.endConfirming()
        let outcome = controller.switchTo(
            plan,
            boundaryAt: pending.proposal.boundaryAt,
            source: response == .switchedEdited ? .userCorrected : .aiSwitch
        )
        switch outcome {
        case let .switched(closed, opened, _):
            undoable = UndoRecord(
                decisionID: pending.decisionID,
                previousEntryID: closed, newEntryID: opened,
                appliedAt: Date(), title: plan.title
            )
            // The user vouched for this, so it becomes a classification example.
            controller.runningEntry?.isHumanConfirmed = (response == .switched)
            update(decisionID: pending.decisionID, response: response, toEntryID: opened)
        case let .correctedInPlace(id):
            controller.runningEntry?.isHumanConfirmed = (response == .switched)
            update(decisionID: pending.decisionID, response: response, toEntryID: id)
        case let .started(id):
            update(decisionID: pending.decisionID, response: response, toEntryID: id)
        case let .rejected(reason):
            AppLogger.log("timer", level: .warning, "switch_apply_rejected reason=\(reason)")
            update(decisionID: pending.decisionID, response: response, toEntryID: nil)
        }
        try? modelContext.save()
        onResolved?()
    }

    private func applyImmediately(_ proposal: FocusPolicy.Proposal, decisionID: UUID) {
        guard let controller = timerController else { return }
        let plan = store.plan(from: proposal)
        let outcome = controller.switchTo(
            plan, boundaryAt: proposal.boundaryAt, source: .aiSwitch
        )
        switch outcome {
        case let .switched(closed, opened, _):
            undoable = UndoRecord(
                decisionID: decisionID,
                previousEntryID: closed, newEntryID: opened,
                appliedAt: Date(), title: plan.title
            )
            update(decisionID: decisionID, response: nil, toEntryID: opened)
        case let .started(id), let .correctedInPlace(id):
            update(decisionID: decisionID, response: nil, toEntryID: id)
        case .rejected:
            break
        }
        onResolved?()
    }

    private func resolve(_ pending: PendingSwitch, response: FocusUserResponse) {
        self.pending = nil
        timerController?.endConfirming()
        update(decisionID: pending.decisionID, response: response, toEntryID: nil)
        onResolved?()
    }

    private func update(decisionID: UUID, response: FocusUserResponse?, toEntryID: UUID?) {
        guard let decision = store.decision(id: decisionID) else { return }
        decision.userResponse = response
        decision.respondedAt = Date()
        decision.toEntryID = toEntryID
        try? modelContext.save()
    }
}
