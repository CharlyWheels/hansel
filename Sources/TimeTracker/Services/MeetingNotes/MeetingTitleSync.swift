import Foundation
import SwiftData

/// Keeps a meeting's title in step with the name the user gave its time entry.
///
/// The entry is what the user corrects — from the meeting's "Edit entry" or the
/// Entries list — so a fixed entry name has to fix the meeting too, not leave the
/// Meetings page showing the calendar event Meeting Notes guessed.
enum MeetingTitleSync {

    /// After the user saved an entry: every meeting linked to it takes its name.
    static func entrySaved(_ entry: TimeEntry, context: ModelContext) {
        let entryID = entry.id
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let records = (try? context.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.linkedEntryID == entryID }
        ))) ?? []
        for record in records where record.title != title {
            AppLogger.log("meetings", level: .info, "title_from_entry meeting=\(record.id)")
            record.title = title
            record.titleIsUserSet = true
        }
        try? context.save()
    }

    /// While linking: an entry the user named or confirmed names its meeting, unless
    /// the meeting's name was already set by the user.
    static func adoptConfirmedTitle(of entry: TimeEntry, into record: MeetingRecord) {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.titleIsUserSet, entry.isHumanConfirmed, !title.isEmpty,
              record.title != title else { return }
        record.title = title
        record.titleIsUserSet = true
    }
}
