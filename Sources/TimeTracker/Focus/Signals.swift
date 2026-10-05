import Foundation

/// Value-type projections of the SwiftData models the segmenter reasons over.
///
/// The segmenter is deliberately kept free of SwiftData and AppKit so it can be unit
/// tested without a `ModelContainer`, the way `RuleEngine` already is. Adapters in
/// `FocusStore` build these from `ActivitySample` / `IdleInterval` / `TimeEntry`.

struct SignalFlags: OptionSet, Sendable, Equatable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let micActive     = SignalFlags(rawValue: 1 << 0)
    static let cameraActive  = SignalFlags(rawValue: 1 << 1)
    static let videoCallApp  = SignalFlags(rawValue: 1 << 2)
    static let conferenceURL = SignalFlags(rawValue: 1 << 3)

    /// Any evidence at all that this instant was part of a call.
    var inCall: Bool {
        !isDisjoint(with: [.micActive, .cameraActive, .videoCallApp, .conferenceURL])
    }
}

struct SignalSample: Equatable, Sendable {
    let timestamp: Date
    let bundleId: String
    let appName: String
    let windowTitle: String?
    let url: String?
    let flags: SignalFlags

    init(
        timestamp: Date,
        bundleId: String,
        appName: String,
        windowTitle: String? = nil,
        url: String? = nil,
        flags: SignalFlags = []
    ) {
        self.timestamp = timestamp
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.flags = flags
    }
}

struct IdleSpan: Equatable, Sendable {
    let start: Date
    let end: Date?

    init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    func duration(now: Date) -> TimeInterval { (end ?? now).timeIntervalSince(start) }
}

/// The current user's response to a calendar invitation.
enum Attendance: String, Sendable, Equatable, CaseIterable {
    case accepted
    case tentative
    case declined
    case pending      // invited, never responded
    case organizer    // it's the user's own event
    case unknown      // could not identify the user among the attendees
}

/// A calendar event as the segmenter sees it — already stripped of EventKit.
struct MeetingWindow: Equatable, Sendable {
    let eventId: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isCancelled: Bool
    /// EventKit `availability == .free` — "focus time" and soft holds book time
    /// without implying the user is in a meeting.
    let showsAsFree: Bool
    let attendance: Attendance
    let attendeeCount: Int
    let hasConferenceURL: Bool
    let calendarId: String
    /// Email domains of the other attendees (the user's own addresses excluded), for
    /// attributing the meeting to a customer.
    var attendeeDomains: [String] = []

    init(
        eventId: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        showsAsFree: Bool = false,
        attendance: Attendance = .unknown,
        attendeeCount: Int = 0,
        hasConferenceURL: Bool = false,
        calendarId: String = ""
    ) {
        self.eventId = eventId
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.showsAsFree = showsAsFree
        self.attendance = attendance
        self.attendeeCount = attendeeCount
        self.hasConferenceURL = hasConferenceURL
        self.calendarId = calendarId
    }
}

/// Projection of the running `TimeEntry`.
struct EntryContext: Equatable, Sendable {
    let id: UUID
    let title: String
    let startAt: Date
    let roleName: String?
    let projectName: String?
    let customerName: String?
    let todoTitle: String?

    init(
        id: UUID,
        title: String,
        startAt: Date,
        roleName: String? = nil,
        projectName: String? = nil,
        customerName: String? = nil,
        todoTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.roleName = roleName
        self.projectName = projectName
        self.customerName = customerName
        self.todoTitle = todoTitle
    }
}

/// Why the segmenter thinks a boundary sits at a given instant.
enum BoundaryReason: String, Equatable, Sendable, CaseIterable {
    case appSwitch
    case topicShift
    case hostChange
    case mediaChange
    case idleGap
    case meetingStart
    case meetingEnd
}
