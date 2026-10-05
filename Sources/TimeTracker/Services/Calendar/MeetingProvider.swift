import Foundation
import AppKit
import EventKit

/// Reads calendar events and strips them down to `MeetingWindow` facts the segmenter
/// can reason about.
///
/// The old `CalendarService` used only `title` and `startDate`, and never read
/// `endDate`, attendance, availability or `isAllDay` — which is precisely why declined
/// invitations, birthdays and "focus time" holds could all start a timer.
///
/// It also fixes three latent bugs in the old scheduling scheme:
///
/// 1. `event(withIdentifier:)` returns the *first* occurrence of a recurring event, so
///    a daily standup always resolved to the same instance, and keying timers by bare
///    event id collapsed a whole series into one. Occurrences are keyed by start date.
/// 2. `DispatchSourceTimer` deadlines run on the uptime clock, which stops while the
///    Mac sleeps, so a timer armed in the morning for an afternoon event fired late.
///    There are no per-event timers any more; the arbiter reads a refreshed list.
/// 3. The 24 h horizon was only ever refreshed on `EKEventStoreChanged`, so a Mac left
///    running for two days scheduled nothing. The cache refreshes on a wall clock.
@MainActor
final class MeetingProvider {

    private let store = EKEventStore()
    private var cache: [MeetingWindow] = []
    private var lastRefresh: Date = .distantPast
    private var storeChangedObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Calendar identifiers the user allows to drive tracking. Nil means "all", which
    /// is the old behaviour and includes birthdays and subscribed calendars.
    var allowedCalendarIds: Set<String>? {
        get {
            guard let raw = UserDefaults.standard.array(forKey: "calendar.allowedIds") as? [String],
                  !raw.isEmpty else { return nil }
            return Set(raw)
        }
        set {
            UserDefaults.standard.set(newValue.map(Array.init) ?? [], forKey: "calendar.allowedIds")
        }
    }

    /// Email addresses belonging to the user, used to identify "me" among attendees when
    /// `isCurrentUser` fails — which it frequently does on Google CalDAV accounts.
    private var myEmailAddresses: Set<String> {
        let raw = UserDefaults.standard.string(forKey: "calendar.myEmails") ?? ""
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    func start() async {
        if Permissions.calendarStatus() != .granted {
            // Ask on the store we will read from, then reset it: a store created before
            // the grant can keep returning no calendars until it is reset.
            guard await Permissions.requestCalendarAccess(on: store) else {
                AppLogger.calendar.warning("Calendar access not granted")
                AppLogger.log("calendar", level: .warning, "access_denied")
                return
            }
            store.reset()
        }
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        // Waking is exactly when the cached window is most likely to be stale.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        refresh(force: true)
    }

    func stop() {
        if let obs = storeChangedObserver {
            NotificationCenter.default.removeObserver(obs)
            storeChangedObserver = nil
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    /// Meetings overlapping the requested range. Refreshes on a wall clock rather than
    /// relying on store-change notifications alone.
    func meetings(from: Date, to: Date) -> [MeetingWindow] {
        refresh(force: false)
        return cache.filter { $0.end >= from && $0.start <= to }
    }

    /// Is a trustworthy event in progress right now? Used to corroborate the mic signal.
    func trustworthyMeetingInProgress(at now: Date = Date()) -> Bool {
        meetings(from: now, to: now).contains {
            $0.start <= now && now < $0.end
            && AttendanceFilter.allowsColdStart($0, allowedCalendarIds: allowedCalendarIds)
        }
    }

    /// The trustworthy meeting in progress that started most recently, if any.
    func currentMeeting(at now: Date = Date()) -> MeetingWindow? {
        meetings(from: now, to: now)
            .filter {
                $0.start <= now && now < $0.end
                    && AttendanceFilter.allowsColdStart($0, allowedCalendarIds: allowedCalendarIds)
            }
            .max { $0.start < $1.start }
    }

    /// The calendars available to choose from, for the Settings allow-list.
    func availableCalendars() -> [(id: String, title: String)] {
        guard Permissions.calendarStatus() == .granted else { return [] }
        return store.calendars(for: .event)
            .map { (id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title < $1.title }
    }

    // MARK: - Refresh

    private func refresh(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastRefresh) > 15 * 60 else { return }
        guard Permissions.calendarStatus() == .granted else { return }
        lastRefresh = now

        store.refreshSourcesIfNecessary()
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { cache = []; return }

        // -2 h so waking mid-meeting still sees it; +26 h so the horizon always moves.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-2 * 3600),
            end: now.addingTimeInterval(26 * 3600),
            calendars: calendars
        )
        cache = store.events(matching: predicate).compactMap(Self.facts(from:))
        AppLogger.calendar.info("Meeting cache refreshed: \(self.cache.count, privacy: .public) events")
        AppLogger.log("calendar", level: .info, "meetings_refreshed count=\(cache.count)")
    }

    // MARK: - Fact extraction

    static func facts(from event: EKEvent) -> MeetingWindow? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let attendees = event.attendees ?? []
        let isOrganizer = event.organizer?.isCurrentUser ?? false

        return MeetingWindow(
            // Recurring events share one identifier, so the occurrence's own start is
            // what makes an instance addressable.
            eventId: "\(event.eventIdentifier ?? "")#\(Int(start.timeIntervalSince1970))",
            title: event.title ?? "Calendar event",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            showsAsFree: event.availability == .free,
            attendance: attendance(for: event, attendees: attendees, isOrganizer: isOrganizer),
            attendeeCount: attendees.count,
            hasConferenceURL: hasConferenceURL(event),
            calendarId: event.calendar?.calendarIdentifier ?? ""
        )
    }

    private static func attendance(
        for event: EKEvent,
        attendees: [EKParticipant],
        isOrganizer: Bool
    ) -> Attendance {
        if let me = attendees.first(where: \.isCurrentUser) {
            return map(me.participantStatus)
        }
        if isOrganizer { return .organizer }
        // An event with no invitees is the user's own block.
        if attendees.isEmpty { return .organizer }
        // `isCurrentUser` is unreliable on some CalDAV accounts, so fall back to
        // matching the user's own addresses before giving up.
        let mine = UserDefaults.standard.string(forKey: "calendar.myEmails") ?? ""
        let addresses = Set(
            mine.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        if !addresses.isEmpty {
            for participant in attendees {
                let email = participant.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                    .lowercased()
                if addresses.contains(email) { return map(participant.participantStatus) }
            }
        }
        // Unknown is deliberately distinct from declined: not being able to find
        // ourselves must not be read as having said no.
        return .unknown
    }

    private static func map(_ status: EKParticipantStatus) -> Attendance {
        switch status {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .pending: return .pending
        default: return .unknown
        }
    }

    private static func hasConferenceURL(_ event: EKEvent) -> Bool {
        if ConferenceCatalog.isConferenceURL(event.url?.absoluteString) { return true }
        if ConferenceCatalog.isConferenceURL(event.location) { return true }
        if ConferenceCatalog.isConferenceURL(event.notes) { return true }
        return false
    }
}
