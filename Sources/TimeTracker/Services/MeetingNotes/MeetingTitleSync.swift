import Foundation
import SwiftData

/// Keeps a meeting's title in step with the name the user gave its time entry.
///
/// The entry is what the user corrects — from the meeting's "Edit entry" or the
/// Entries list — so a fixed entry name has to fix the meeting too, not leave the
/// Meetings page showing the calendar event Meeting Notes guessed.
@MainActor
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
            record.titleWrittenToNotes = false
        }
        writePendingTitles(records)
        try? context.save()
    }

    /// Writes names the user set into Meeting Notes, so its own list shows them too.
    ///
    /// Best effort: the name in Hansel is already changed and stays changed whatever
    /// happens here. A file that could not be written is tried again only once
    /// Meeting Notes has changed it (an update may fix the layout), not every scan.
    static func writePendingTitles(_ records: [MeetingRecord]) {
        guard MeetingNotesTitleWriter.isEnabled else { return }
        for record in records where record.titleIsUserSet && !record.titleWrittenToNotes {
            let attempt = WriteAttempt(title: record.title, fileModifiedAt: record.fileModifiedAt)
            if failedAttempts[record.id] == attempt { continue }
            switch MeetingNotesTitleWriter.write(title: record.title, toFolder: record.folderURL) {
            case .written, .alreadyCurrent:
                record.titleWrittenToNotes = true
                failedAttempts[record.id] = nil
                AppLogger.log("meetings", level: .info, "title_written_to_notes meeting=\(record.id)")
            case .notWritten(let reason):
                failedAttempts[record.id] = attempt
                AppLogger.log("meetings", level: .warning, "title_not_written meeting=\(record.id) reason=\(reason)")
            }
        }
    }

    private struct WriteAttempt: Equatable {
        let title: String
        let fileModifiedAt: Date
    }
    /// Attempts that did not write, so an unchanged file is not retried every scan.
    private static var failedAttempts: [UUID: WriteAttempt] = [:]

    /// While linking: an entry the user named or confirmed names its meeting, unless
    /// the meeting's name was already set by the user.
    static func adoptConfirmedTitle(of entry: TimeEntry, into record: MeetingRecord) {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.titleIsUserSet, entry.isHumanConfirmed, !title.isEmpty,
              record.title != title else { return }
        record.title = title
        record.titleIsUserSet = true
        record.titleWrittenToNotes = false
    }
}
