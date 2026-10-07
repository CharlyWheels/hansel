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
    /// The user named this meeting (through its time entry), so re-reading Meeting
    /// Notes' file must not put its own title back. Meeting Notes titles a recording
    /// after the calendar event chosen when recording started, which can be the wrong
    /// one of several overlapping invitations.
    var titleIsUserSet: Bool = false
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

    // MARK: Speakers
    /// Set once both tracks were diarised (or found to have no audio).
    var diarizedAt: Date? = nil
    var diarizationError: String? = nil
    /// JSON `[SpeakerSegment]`: who spoke when, per track.
    var speakerSegments: Data? = nil
    /// Set once the model was asked to name the speakers.
    var speakerNamesSuggestedAt: Date? = nil
    /// Meeting Notes' summary rewritten with the speakers' names (Meeting Notes' own
    /// file is never changed).
    var namedSummary: String? = nil
    /// The names it was written with, to rewrite it only when they change.
    var namedSummaryNamesKey: String? = nil
    var namedSummaryError: String? = nil

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
