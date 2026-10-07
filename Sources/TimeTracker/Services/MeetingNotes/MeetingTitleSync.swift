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
        let records = (try? context.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.linkedEntryID == entryID }
        ))) ?? []
        // Saving an entry by hand is itself the confirmation.
        for record in records { adoptConfirmedTitle(of: entry, into: record, savedByUser: true) }
        writePendingTitles(records)
        try? context.save()
    }

    /// The meeting takes the name of the entry it is linked to, once the user named
    /// or confirmed that entry — and again whenever the link moves to another entry
    /// or the entry is renamed. Splitting an entry in two, for example, re-links the
    /// meeting to the part that covers it, and the meeting follows.
    static func adoptConfirmedTitle(of entry: TimeEntry, into record: MeetingRecord, savedByUser: Bool = false) {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entry.isHumanConfirmed || savedByUser, !title.isEmpty else { return }
        guard record.titleEntryID != entry.id || record.titleEntryTitle != title else { return }
        record.titleEntryID = entry.id
        record.titleEntryTitle = title
        guard record.title != title else { return }
        AppLogger.log("meetings", level: .info, "title_from_entry meeting=\(record.id)")
        record.title = title
        record.titleIsUserSet = true
        record.titleWrittenToNotes = false
    }

    /// Renamed on the meeting page. Kept until the linked entry changes or is renamed.
    static func rename(_ record: MeetingRecord, to newTitle: String, context: ModelContext) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let entryID = record.linkedEntryID,
           let entry = try? context.fetch(FetchDescriptor<TimeEntry>(
               predicate: #Predicate { $0.id == entryID }
           )).first {
            record.titleEntryID = entry.id
            record.titleEntryTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard record.title != title else { try? context.save(); return }
        AppLogger.log("meetings", level: .info, "title_renamed meeting=\(record.id)")
        record.title = title
        record.titleIsUserSet = true
        record.titleWrittenToNotes = false
        writePendingTitles([record])
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

}
