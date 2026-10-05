import Foundation
import EventKit
import SwiftData

/// Reads iCloud calendars (including shared) via EventKit, schedules per-event timers,
/// and asks `TimerController` to auto-start when an event begins.
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private let modelContext: ModelContext
    private weak var timerController: TimerController?
    private weak var idleMonitor: IdleMonitor?

    private var scheduledTimers: [String: DispatchSourceTimer] = [:]
    private var storeChangedObserver: NSObjectProtocol?

    init(
        modelContext: ModelContext,
        timerController: TimerController,
        idleMonitor: IdleMonitor?
    ) {
        self.modelContext = modelContext
        self.timerController = timerController
        self.idleMonitor = idleMonitor
    }

    /// Requests calendar access if needed, then starts watching.
    func start() async {
        if Permissions.calendarStatus() != .granted {
            let granted = await Permissions.requestCalendarAccess()
            guard granted else {
                AppLogger.calendar.warning("Calendar access not granted")
                AppLogger.log("calendar", level: .warning, "access_denied")
                return
            }
        }
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshSchedule() }
        }
        idleMonitor?.onTransition { [weak self] isIdle in
            if !isIdle { Task { @MainActor in self?.fireBackfilledIfAny() } }
        }
        await refreshSchedule()
    }

    func stop() {
        if let obs = storeChangedObserver {
            NotificationCenter.default.removeObserver(obs)
            storeChangedObserver = nil
        }
        cancelAllTimers()
    }

    // MARK: - Scheduling

    private func refreshSchedule() async {
        cancelAllTimers()
        let calendars = store.calendars(for: .event).filter(Self.isICloudCalendar)
        guard !calendars.isEmpty else {
            AppLogger.calendar.info("No iCloud calendars found")
            AppLogger.log("calendar", level: .info, "no_icloud_calendars")
            return
        }
        let now = Date()
        let end = now.addingTimeInterval(24 * 3600)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
        var scheduled = 0
        for event in events where (event.startDate ?? .distantPast) > now {
            guard isTrustworthy(event) else { continue }
            scheduleTrigger(for: event)
            syncLink(for: event)
            scheduled += 1
        }
        AppLogger.calendar.info("Scheduled \(scheduled, privacy: .public) upcoming events from \(calendars.count, privacy: .public) iCloud calendar(s)")
        AppLogger.log("calendar", level: .info, "scheduled count=\(scheduled)")
    }

    private func scheduleTrigger(for event: EKEvent) {
        guard let eventId = event.eventIdentifier, let startDate = event.startDate else { return }
        let delay = max(0, startDate.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.fireEvent(eventId: eventId) }
        }
        timer.resume()
        scheduledTimers[eventId] = timer
    }

    private func cancelAllTimers() {
        scheduledTimers.values.forEach { $0.cancel() }
        scheduledTimers.removeAll()
    }

    // MARK: - Firing

    private func fireEvent(eventId: String) {
        guard let event = store.event(withIdentifier: eventId),
              let controller = timerController else { return }

        if controller.isRunning {
            AppLogger.calendar.info("Event fired while timer running — not switching. title=\(event.title ?? "", privacy: .public)")
            AppLogger.log("calendar", level: .info, "fire_while_running title=\(event.title ?? "")")
            return
        }
        if idleMonitor?.isIdle == true {
            // Defer — we'll trigger on idle-exit.
            if let link = fetchLink(eventId: eventId) {
                link.lastFired = nil
                try? modelContext.save()
            }
            AppLogger.calendar.notice("Event fired while idle — deferring")
            AppLogger.log("calendar", level: .notice, "fire_while_idle title=\(event.title ?? "")")
            return
        }
        start(controller: controller, event: event)
    }

    private func fireBackfilledIfAny() {
        // When user returns from idle, start any missed event whose start was within the last 30 min.
        guard let controller = timerController, !controller.isRunning else { return }
        let now = Date()
        let since = now.addingTimeInterval(-30 * 60)
        let calendars = store.calendars(for: .event).filter(Self.isICloudCalendar)
        let predicate = store.predicateForEvents(withStart: since, end: now, calendars: calendars)
        let recent = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }

        for event in recent {
            guard let eventId = event.eventIdentifier else { continue }
            if let link = fetchLink(eventId: eventId), link.lastFired != nil { continue }
            start(controller: controller, event: event)
            break
        }
    }

    /// Whether this event may start a timer at all.
    ///
    /// The old code fired for any event on any calendar, which is the main reason the
    /// tracker "followed the calendar too much": declined invitations, all-day events,
    /// birthdays, subscribed calendars and "focus time" holds could all yank the timer.
    /// Switching *while* an entry runs is the arbiter's job; this gate only governs
    /// starting from cold.
    private func isTrustworthy(_ event: EKEvent) -> Bool {
        guard let facts = MeetingProvider.facts(from: event) else { return false }
        let allowed = UserDefaults.standard.array(forKey: "calendar.allowedIds") as? [String]
        let allowSet = (allowed?.isEmpty == false) ? Set(allowed!) : nil
        let weight = AttendanceFilter.weight(for: facts, allowedCalendarIds: allowSet)
        if weight <= 0 {
            AppLogger.calendar.info("Event not trustworthy — not starting. title=\(event.title ?? "", privacy: .public)")
            AppLogger.log("calendar", level: .info, "event_untrusted title=\(event.title ?? "") attendance=\(facts.attendance.rawValue) allDay=\(facts.isAllDay) free=\(facts.showsAsFree)")
            return false
        }
        return true
    }

    private func start(controller: TimerController, event: EKEvent) {
        guard isTrustworthy(event) else { return }
        let (role, project, customer) = classify(event: event)
        let title = event.title ?? "Calendar event"
        let startAt = event.startDate ?? Date()
        controller.startFromCalendar(
            title: title,
            startAt: startAt,
            role: role,
            project: project,
            customer: customer,
            eventIdentifier: event.eventIdentifier ?? ""
        )
        if let link = fetchLink(eventId: event.eventIdentifier ?? "") {
            link.lastFired = Date()
            try? modelContext.save()
        }
        AppLogger.calendar.info("Started timer for event: \(title, privacy: .public)")
        AppLogger.log("calendar", level: .info, "auto_started title=\(title)")
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
    private func classify(event: EKEvent) -> (Role?, Project?, Customer?) {
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.isHumanConfirmed == true },
            sortBy: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
        )
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        let target = Self.normalize(event.title ?? "")
        guard !target.isEmpty else { return (nil, nil, nil) }

        if let match = entries.first(where: { Self.normalize($0.title) == target }) {
            return (match.role, match.project, match.customer)
        }
        return (nil, nil, nil)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - CalendarEventLink

    private func syncLink(for event: EKEvent) {
        guard let eventId = event.eventIdentifier else { return }
        if let link = fetchLink(eventId: eventId) {
            if let start = event.startDate { link.lastSeenStart = start }
            link.lastSeenTitle = event.title ?? ""
        } else {
            let link = CalendarEventLink(
                eventIdentifier: eventId,
                lastSeenStart: event.startDate ?? Date(),
                lastSeenTitle: event.title ?? ""
            )
            modelContext.insert(link)
        }
        try? modelContext.save()
    }

    private func fetchLink(eventId: String) -> CalendarEventLink? {
        let descriptor = FetchDescriptor<CalendarEventLink>(
            predicate: #Predicate<CalendarEventLink> { $0.eventIdentifier == eventId }
        )
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Calendars

    /// Use every calendar the event store exposes. The old iCloud-only filter missed
    /// sources whose title wasn't literally "iCloud" (localized OS, account email as source,
    /// Google/Exchange accounts, etc.). If the user wants to narrow this later, we add a
    /// calendar-chooser setting.
    private static func isICloudCalendar(_ calendar: EKCalendar) -> Bool { true }
}
