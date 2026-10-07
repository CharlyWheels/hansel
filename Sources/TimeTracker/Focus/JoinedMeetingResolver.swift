import Foundation

/// Names the meeting the user is in, from the calendar, once `MeetingDetector` says
/// they are in a call.
///
/// The old rule only accepted an event that would also have been allowed to start a
/// timer from cold — accepted, "busy", with attendees. Being in a call is already the
/// evidence, so here any event that is not declined, cancelled or all-day may name it:
/// an unanswered invitation the user is visibly attending is still that meeting.
enum JoinedMeetingResolver {

    /// Joining this early still counts as joining the upcoming event.
    static let earlyJoinSeconds: TimeInterval = 5 * 60

    static func resolve(
        callSince: Date,
        meetings: [MeetingWindow],
        now: Date,
        allowedCalendarIds: Set<String>?
    ) -> (meeting: MeetingWindow, since: Date)? {
        let eligible = meetings.filter { meeting in
            !meeting.isCancelled && !meeting.isAllDay && meeting.attendance != .declined
                && !meeting.showsAsFree && meeting.end > meeting.start
                && (allowedCalendarIds?.contains(meeting.calendarId) ?? true)
        }
        // The event in progress, most recently started first; one about to start only
        // when nothing else is on, so an overrunning meeting is not cut short early.
        let started = eligible.filter { $0.start <= now && now < $0.end }
        let upcoming = eligible.filter {
            $0.start > now && $0.start <= now.addingTimeInterval(earlyJoinSeconds)
        }
        let pool = started.isEmpty ? upcoming : started
        guard let best = pool.max(by: { rank($0) < rank($1) }) else { return nil }
        return (best, callSince)
    }

    /// Real meetings before solo blocks, then the most recently started.
    private static func rank(_ meeting: MeetingWindow) -> (Int, Date) {
        (meeting.isRealMeeting ? 1 : 0, meeting.start)
    }
}
