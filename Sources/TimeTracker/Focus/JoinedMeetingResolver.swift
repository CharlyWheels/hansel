import Foundation

/// Names the meeting the user is in, once `MeetingDetector` says they are in a call.
///
/// The old rule only accepted an event that would also have been allowed to start a
/// timer from cold — accepted, "busy", with attendees. Being in a call is already the
/// evidence, so here any event that is not declined, cancelled or all-day may name it:
/// an unanswered invitation the user is visibly attending is still that meeting.
enum JoinedMeetingResolver {

    /// Joining this early still counts as joining the upcoming event.
    static let earlyJoinSeconds: TimeInterval = 5 * 60
    /// How far a recording may start from its event and still be matched to it.
    static let recordingMatchSlack: TimeInterval = 30 * 60

    static func resolve(
        callSince: Date,
        recording: ActiveRecording?,
        meetings: [MeetingWindow],
        now: Date,
        allowedCalendarIds: Set<String>?
    ) -> (meeting: MeetingWindow, since: Date)? {
        let eligible = meetings.filter { meeting in
            !meeting.isCancelled && !meeting.isAllDay && meeting.attendance != .declined
                && meeting.end > meeting.start
                && (allowedCalendarIds?.contains(meeting.calendarId) ?? true)
        }

        // 1. A recording names its meeting exactly: Meeting Notes titles the folder
        //    after the event the user chose, and starts it when the meeting starts.
        if let recording {
            let matches = eligible.filter {
                let nearStart = abs($0.start.timeIntervalSince(recording.startedAt)) <= recordingMatchSlack
                let during = $0.start <= recording.startedAt && recording.startedAt < $0.end
                return MeetingRecordingProbe.slugify($0.title) == recording.slug && (nearStart || during)
            }
            if let match = matches.min(by: {
                abs($0.start.timeIntervalSince(recording.startedAt))
                    < abs($1.start.timeIntervalSince(recording.startedAt))
            }) {
                return (match, recording.startedAt)
            }
        }

        // 2. The calendar event in progress, most recently started first; one about to
        //    start only when nothing else is on.
        let started = eligible.filter { $0.start <= now && now < $0.end && !$0.showsAsFree }
        let upcoming = eligible.filter {
            $0.start > now && $0.start <= now.addingTimeInterval(earlyJoinSeconds) && !$0.showsAsFree
        }
        let pool = started.isEmpty ? upcoming : started
        if let best = pool.max(by: { rank($0) < rank($1) }) {
            return (best, recording?.startedAt ?? callSince)
        }

        // 3. An unscheduled call that is being recorded is still a meeting.
        if let recording {
            let meeting = MeetingWindow(
                eventId: "recording#\(recording.folderName)",
                title: recording.fallbackTitle,
                start: recording.startedAt,
                end: max(now, recording.startedAt).addingTimeInterval(3600),
                attendance: .organizer
            )
            return (meeting, recording.startedAt)
        }
        return nil
    }

    /// Real meetings before solo blocks, then the most recently started.
    private static func rank(_ meeting: MeetingWindow) -> (Int, Date) {
        (meeting.isRealMeeting ? 1 : 0, meeting.start)
    }
}
