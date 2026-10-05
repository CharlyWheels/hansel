import Foundation
import AppKit
import SwiftData

/// Starts the timer from cold when a trustworthy calendar event begins.
///
/// Event data comes from `MeetingProvider`, whose cache is keyed by *occurrence*
/// (`eventIdentifier#start`) and refreshed on a wall clock. The previous version kept
/// its own `EKEventStore` and per-event `DispatchSourceTimer`s, which had three bugs:
/// `event(withIdentifier:)` returned the first occurrence of a recurring series (a
/// daily standup started an entry back-dated to the day the series was created),
/// uptime-clock deadlines fired late after the Mac slept, and the 24 h horizon was
/// only refreshed on store changes. Polling a fresh list every 30 s has none of them.
///
/// Switching *while* an entry runs is the arbiter's job; this only starts from cold.
@MainActor
final class CalendarService {
    private let modelContext: ModelContext
    private weak var timerController: TimerController?
    private weak var idleMonitor: IdleMonitor?
    private weak var meetingProvider: MeetingProvider?

    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// How late an event may still start a timer: covers sleep, a busy main thread,
    /// and coming back from idle a little after the meeting began.
    static let catchUpSeconds: TimeInterval = 30 * 60

    init(
        modelContext: ModelContext,
        timerController: TimerController,
        idleMonitor: IdleMonitor?,
        meetingProvider: MeetingProvider
    ) {
        self.modelContext = modelContext
        self.timerController = timerController
        self.idleMonitor = idleMonitor
        self.meetingProvider = meetingProvider
    }

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        idleMonitor?.onTransition { [weak self] isIdle in
            if !isIdle { Task { @MainActor in self?.tick() } }
        }
        tick()
        AppLogger.log("calendar", level: .info, "calendar_autostart_started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    // MARK: - Tick

    private func tick() {
        guard let controller = timerController, let provider = meetingProvider else { return }
        let now = Date()
        let inProgress = provider.meetings(from: now, to: now)
            .filter { $0.start <= now && now < $0.end }

        if controller.isRunning {
            // Something is already tracked. Remember these occurrences as handled so
            // they cannot start a back-dated entry later, once the user stops.
            for meeting in inProgress { markHandled(meeting, entryID: nil) }
            return
        }
        // Never start while the user is away; the next tick after they return will.
        if idleMonitor?.isIdle == true { return }

        let handled = Set(inProgress.compactMap { fetchLink(eventId: $0.eventId)?.lastFired != nil ? $0.eventId : nil })
        guard let (meeting, startAt) = Self.coldStart(
            meetings: inProgress,
            now: now,
            handledIds: handled,
            latestEnd: controller.latestEndedAt(),
            allowedCalendarIds: provider.allowedCalendarIds
        ) else { return }

        let (role, project, customer) = classify(title: meeting.title)
        controller.startFromCalendar(
            title: meeting.title,
            startAt: startAt,
            role: role,
            project: project,
            customer: customer,
            eventIdentifier: meeting.eventId
        )
        markHandled(meeting, entryID: controller.runningEntry?.id)
        AppLogger.calendar.info("Started timer for a calendar event")
        AppLogger.log("calendar", level: .info, "auto_started late=\(Int(now.timeIntervalSince(meeting.start)))s")
    }

    /// Which in-progress event, if any, should start a timer now, and from when.
    ///
    /// Pure so the rules are testable: the event must be trustworthy, not already
    /// handled, and have begun within the catch-up window. The entry is back-dated to
    /// the event's start, but never over the end of the last entry the user closed.
    static func coldStart(
        meetings: [MeetingWindow],
        now: Date,
        handledIds: Set<String>,
        latestEnd: Date?,
        allowedCalendarIds: Set<String>?
    ) -> (MeetingWindow, Date)? {
        let eligible = meetings.filter { meeting in
            meeting.start <= now && now < meeting.end
                && now.timeIntervalSince(meeting.start) <= catchUpSeconds
                && !handledIds.contains(meeting.eventId)
                && AttendanceFilter.allowsColdStart(meeting, allowedCalendarIds: allowedCalendarIds)
        }
        // The most recently started event is the one the user is most likely in.
        guard let meeting = eligible.max(by: { $0.start < $1.start }) else { return nil }
        var startAt = meeting.start
        if let latestEnd { startAt = max(startAt, min(latestEnd, now)) }
        return (meeting, startAt)
    }

    // MARK: - Classification

    /// Inherits role/project/customer from the most recent *human-confirmed* entry whose
    /// title matches the event exactly (after normalization).
    ///
    /// The previous implementation also accepted a bidirectional substring match
    /// (`n.contains(target) || target.contains(n)`). That was far too loose: an event
    /// titled "Sync" matched a past entry "Sync roadmap Acme" and silently inherited
    /// Acme's project and customer. A one-word event title matched almost anything.
    /// Exact-match-or-nothing is the correct trade — a nil classification is harmless,
    /// a confidently wrong one is not.
    private func classify(title: String) -> (Role?, Project?, Customer?) {
        let target = Self.normalize(title)
        guard !target.isEmpty else { return (nil, nil, nil) }
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.isHumanConfirmed == true },
            sortBy: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        if let match = entries.first(where: { Self.normalize($0.title) == target }) {
            return (match.role, match.project, match.customer)
        }
        return (nil, nil, nil)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - CalendarEventLink (keyed by occurrence)

    private func markHandled(_ meeting: MeetingWindow, entryID: UUID?) {
        if let link = fetchLink(eventId: meeting.eventId) {
            guard link.lastFired == nil else { return }
            link.lastFired = Date()
            link.linkedEntryID = entryID
        } else {
            modelContext.insert(CalendarEventLink(
                eventIdentifier: meeting.eventId,
                linkedEntryID: entryID,
                lastSeenStart: meeting.start,
                lastSeenTitle: meeting.title,
                lastFired: Date()
            ))
        }
        try? modelContext.save()
    }

    private func fetchLink(eventId: String) -> CalendarEventLink? {
        let descriptor = FetchDescriptor<CalendarEventLink>(
            predicate: #Predicate<CalendarEventLink> { $0.eventIdentifier == eventId }
        )
        return try? modelContext.fetch(descriptor).first
    }
}
