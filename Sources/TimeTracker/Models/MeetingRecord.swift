import Foundation
import SwiftData

/// A meeting recorded by Meeting Notes, as Hansel knows it.
///
/// Only what lists and matching need is copied. The transcript, decisions and topics are
/// read from the archive folder when a meeting is opened, so they live in one place and a
/// transcript Meeting Notes deletes on schedule is not kept alive here.
///
/// Links to entries, projects and customers are ids, like `CalendarEventLink`, so this
/// model adds no inverse relationships to the existing ones.
@Model
final class MeetingRecord {
    /// Meeting Notes' own id; stable across renames and folder moves.
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: String
    var eventIdentifier: String?
    var folderPath: String
    /// Modification date of `.meeting.json` when last read, to re-read only on change.
    var fileModifiedAt: Date
    var summary: String
    var participantNames: [String] = []
    var participantEmails: [String] = []
    var actionItemCount: Int = 0
    var hasTranscript: Bool = false
    /// The time entry that best covers the meeting, if any.
    var linkedEntryID: UUID?
    var importedAt: Date
    /// Set once proposals were made from this meeting, so a later re-read (a regenerated
    /// summary, a rename) does not propose the same tasks twice.
    var proposalsCreatedAt: Date?
    /// Set once the model has refined (or extracted) this meeting's proposals.
    var aiEnrichedAt: Date?
    var aiAttempts: Int = 0
    var aiLastError: String?

    init(
        id: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: String = "complete",
        eventIdentifier: String? = nil,
        folderPath: String,
        fileModifiedAt: Date,
        summary: String = "",
        importedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.eventIdentifier = eventIdentifier
        self.folderPath = folderPath
        self.fileModifiedAt = fileModifiedAt
        self.summary = summary
        self.importedAt = importedAt
    }

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    var attendeeDomains: [String] {
        participantEmails.compactMap { CustomerMatcher.domain(ofEmail: $0) }
    }
}
