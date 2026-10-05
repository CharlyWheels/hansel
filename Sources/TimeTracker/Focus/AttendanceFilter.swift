import Foundation

/// Scores how much a calendar event should be trusted as evidence that the user is
/// actually working on it right now.
///
/// The old behaviour started a timer for any event on any calendar at its scheduled
/// start, which is why declined invitations, "focus time" holds, birthdays and
/// subscribed calendars all yanked the timer. A scheduled event is a *hypothesis*
/// about what the user is doing; corroboration from the microphone is evidence.
enum AttendanceFilter {

    /// 0 means "never propose a boundary for this event".
    static func weight(
        for meeting: MeetingWindow,
        callShareAfter: Double = 0,
        allowedCalendarIds: Set<String>? = nil,
        titleOverlapsActivity: Bool = false
    ) -> Double {
        // --- Hard rejections: these must never move the timer. ---
        if meeting.isCancelled { return 0 }
        if meeting.isAllDay { return 0 }
        if meeting.attendance == .declined { return 0 }
        if meeting.end <= meeting.start { return 0 }
        if meeting.end.timeIntervalSince(meeting.start) > 8 * 3600 { return 0 }
        if let allowed = allowedCalendarIds, !allowed.contains(meeting.calendarId) { return 0 }

        var weight = 0.5

        // A "free" block is a hold, not an appointment. Focus time is the classic case:
        // the user booked the slot precisely so they could keep doing what they choose.
        if meeting.showsAsFree { weight *= 0.3 }

        switch meeting.attendance {
        case .pending:   weight *= 0.5     // invited, never responded
        case .tentative: weight *= 0.7
        case .accepted, .organizer: weight += 0.2
        case .unknown:   break             // can't identify the user; don't punish
        case .declined:  return 0          // already handled above
        }

        if meeting.attendeeCount >= 2 { weight += 0.15 }
        if meeting.hasConferenceURL { weight += 0.15 }

        // Corroboration. An accepted meeting the user is visibly not attending — no
        // microphone, no matching activity — should not on its own clear the ask
        // threshold. This is the concrete answer to "it follows the calendar too much".
        let attended = callShareAfter >= 0.5
        if !attended && callShareAfter < 0.1 && !titleOverlapsActivity {
            weight *= 0.6
        }

        return Similarity.clamp01(weight)
    }

    /// True when the microphone (or a call app) corroborates the scheduled meeting,
    /// which promotes the boundary to a "hard" one the arbiter may act on immediately.
    static func isCorroborated(callShareAfter: Double) -> Bool {
        callShareAfter >= 0.5
    }
}
