import XCTest
import SwiftData
@testable import TimeTracker

/// Reading the Meeting Notes archive: the file format, the folder layout, transcript
/// paragraphs and linking a meeting to the entry that covers it.
@MainActor
final class MeetingNotesImportTests: XCTestCase {

    // MARK: - Fixtures

    static let meetingID = UUID(uuidString: "6F2C1D7E-3B1A-4C55-9E0B-1A2B3C4D5E6F")!

    /// Shaped like Meeting Notes writes it: sorted keys, ISO 8601 dates, plus fields
    /// Hansel does not know about and one action item it cannot read.
    static func sampleJSON(id: UUID = meetingID, title: String = "Roadmap planning",
                           withInsights: Bool = true) -> Data {
        let insights = withInsights ? """
        ,
          "insights" : {
            "actionItems" : [
              { "owner" : "Carlos", "text" : "Send the revised migration plan to Acme.", "timestamp" : 754 },
              { "owner" : "Jan", "text" : "Book the follow-up workshop", "timestamp" : 1210 },
              { "text" : 42 },
              { "owner" : "", "text" : "Check licence costs", "timestamp" : 1500 }
            ],
            "decisions" : [ { "text" : "Ship in two phases", "timestamp" : 600 } ],
            "generatedAt" : "2026-10-06T11:20:00Z",
            "generator" : "codex",
            "keyStatements" : [],
            "openQuestions" : [],
            "summary" : "We agreed to ship the migration in two phases.",
            "topics" : [ { "end" : 900, "start" : 0, "summary" : "Scope", "title" : "Migration" } ]
          }
        """ : ""
        return """
        {
          "calendar" : {
            "calendarTitle" : "Work",
            "eventIdentifier" : "EV-123",
            "meetingURL" : "https://meet.example.com/abc",
            "organizer" : { "email" : "jan@acme.com", "name" : "Jan" },
            "participants" : [
              { "email" : "jan@acme.com", "name" : "Jan" },
              { "email" : "carlos@nedap.com", "name" : "Carlos" }
            ],
            "scheduledEnd" : "2026-10-06T11:00:00Z",
            "scheduledStart" : "2026-10-06T10:30:00Z"
          },
          "codexThreadID" : null,
          "endedAt" : "2026-10-06T11:02:00Z",
          "futureField" : { "anything" : true },
          "id" : "\(id.uuidString)",
          "startedAt" : "2026-10-06T10:30:00Z",
          "status" : "complete",
          "title" : "\(title)",
          "transcript" : [
            { "end" : 3, "id" : "\(UUID().uuidString)", "source" : "microphone", "speaker" : "Unknown", "start" : 0, "text" : "Hi all," },
            { "end" : 6, "id" : "\(UUID().uuidString)", "source" : "microphone", "speaker" : "Unknown", "start" : 4, "text" : "shall we start?" },
            { "end" : 12, "id" : "\(UUID().uuidString)", "source" : "system", "speaker" : "Unknown", "start" : 8, "text" : "Yes, go ahead." }
          ],
          "transcriptionVersion" : 2\(insights)
        }
        """.data(using: .utf8)!
    }

    // MARK: - Document

    func test_decode_readsTheFieldsHanselUses() throws {
        let doc = try MeetingNotesDocument.decode(Self.sampleJSON())
        XCTAssertEqual(doc.id, Self.meetingID)
        XCTAssertEqual(doc.title, "Roadmap planning")
        XCTAssertEqual(doc.calendar?.eventIdentifier, "EV-123")
        XCTAssertEqual(doc.transcript.count, 3)
        XCTAssertEqual(doc.insights?.summary, "We agreed to ship the migration in two phases.")
        XCTAssertEqual(doc.insights?.decisions.first?.text, "Ship in two phases")
    }

    func test_decode_skipsAnUnreadableActionItemInsteadOfFailing() throws {
        let doc = try MeetingNotesDocument.decode(Self.sampleJSON())
        XCTAssertEqual(doc.actionItems.map(\.text),
                       ["Send the revised migration plan to Acme.", "Book the follow-up workshop", "Check licence costs"])
    }

    func test_decode_withoutInsights() throws {
        let doc = try MeetingNotesDocument.decode(Self.sampleJSON(withInsights: false))
        XCTAssertNil(doc.insights)
        XCTAssertTrue(doc.actionItems.isEmpty)
    }

    func test_participants_includeOrganizerOnce() throws {
        let doc = try MeetingNotesDocument.decode(Self.sampleJSON())
        XCTAssertEqual(doc.participants.compactMap(\.email), ["jan@acme.com", "carlos@nedap.com"])
    }

    func test_decode_acceptsFractionalSeconds() throws {
        let json = #"{"id":"\#(UUID().uuidString)","startedAt":"2026-10-06T10:30:00.123Z","transcript":[]}"#
        let doc = try MeetingNotesDocument.decode(Data(json.utf8))
        XCTAssertEqual(doc.title, "Untitled meeting")
    }

    // MARK: - Archive folder

    func test_scan_findsMeetingFoldersByDate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = root.appending(path: "2026/10/06/1030-roadmap-planning-6f2c1d7e")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Self.sampleJSON().write(to: meeting.appending(path: ".meeting.json"))
        // Noise that must be ignored: a folder without state, and a non-date folder.
        try FileManager.default.createDirectory(at: root.appending(path: "2026/10/06/empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Templates/x"), withIntermediateDirectories: true)

        let entries = MeetingNotesArchive.scan(root: root)
        XCTAssertEqual(entries.map(\.folder.lastPathComponent), ["1030-roadmap-planning-6f2c1d7e"])
        XCTAssertEqual(try MeetingNotesArchive.load(entries[0].folder).id, Self.meetingID)
    }

    func test_resolvedRoot_prefersHanselsOwnSetting() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defaults.set("/tmp/my-meetings", forKey: MeetingNotesArchive.pathDefaultsKey)
        XCTAssertEqual(MeetingNotesArchive.resolvedRoot(defaults: defaults).path, "/tmp/my-meetings")
    }

    // MARK: - Transcript

    func test_paragraphs_joinFragmentsFromTheSameTrack() throws {
        let doc = try MeetingNotesDocument.decode(Self.sampleJSON())
        let paragraphs = TranscriptGrouping.paragraphs(doc.transcript)
        XCTAssertEqual(paragraphs.map(\.text), ["Hi all, shall we start?", "Yes, go ahead."])
        XCTAssertEqual(paragraphs.map(\.speaker), [.me, .others])
    }

    func test_paragraphs_breakAfterAPause() {
        let turns = [
            MeetingNotesDocument.Turn(start: 0, text: "One", source: "system"),
            MeetingNotesDocument.Turn(start: 40, text: "Two", source: "system")
        ]
        XCTAssertEqual(TranscriptGrouping.paragraphs(turns).count, 2)
    }

    func test_timestamp() {
        XCTAssertEqual(TranscriptGrouping.timestamp(754), "12:34")
        XCTAssertEqual(TranscriptGrouping.timestamp(3725), "1:02:05")
    }

    func test_excerpt_keepsOnlyTheWindow() {
        let turns = (0..<20).map { MeetingNotesDocument.Turn(start: Double($0 * 30), text: "t\($0)", source: "system") }
        let text = TranscriptGrouping.excerpt(turns, around: 300, before: 30, after: 30)
        XCTAssertTrue(text.contains("t9") && text.contains("t10") && text.contains("t11"))
        XCTAssertFalse(text.contains("t8 ") || text.contains("t12"))
    }

    // MARK: - Linking to entries

    func test_bestEntry_picksTheEntryCoveringMostOfTheMeeting() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(3600)
        let edge = TimeEntry(title: "before", startAt: start.addingTimeInterval(-3600), endAt: start.addingTimeInterval(300))
        let main = TimeEntry(title: "meeting", startAt: start.addingTimeInterval(120), endAt: end)
        XCTAssertEqual(MeetingContextResolver.bestEntry(start: start, end: end, entries: [edge, main])?.title, "meeting")
    }

    func test_bestEntry_ignoresAnEntryThatOnlyTouchesTheMeeting() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(3600)
        let edge = TimeEntry(title: "before", startAt: start.addingTimeInterval(-3600), endAt: start.addingTimeInterval(300))
        XCTAssertNil(MeetingContextResolver.bestEntry(start: start, end: end, entries: [edge]))
    }

    // MARK: - Importer

    func test_apply_insertsUpdatesOnRenameAndRemoves() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let importer = MeetingImporter(modelContext: ctx)
        var removed: [UUID] = []
        importer.onRemoved = { removed += $0 }

        let doc = try MeetingNotesDocument.decode(Self.sampleJSON())
        let first = MeetingNotesArchive.Entry(folder: URL(fileURLWithPath: "/a/2026/10/06/1030-roadmap"), modifiedAt: Date())
        importer.apply(loaded: [(first, doc)], presentPaths: [first.folder.path])
        var records = try ctx.fetch(FetchDescriptor<MeetingRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].participantEmails, ["jan@acme.com", "carlos@nedap.com"])
        XCTAssertEqual(records[0].actionItemCount, 3)

        // Renamed in Meeting Notes: new title and folder, same id.
        let renamedDoc = try MeetingNotesDocument.decode(Self.sampleJSON(title: "Roadmap v2"))
        let moved = MeetingNotesArchive.Entry(folder: URL(fileURLWithPath: "/a/2026/10/06/1030-roadmap-v2"), modifiedAt: Date())
        importer.apply(loaded: [(moved, renamedDoc)], presentPaths: [moved.folder.path])
        records = try ctx.fetch(FetchDescriptor<MeetingRecord>())
        XCTAssertEqual(records.map(\.title), ["Roadmap v2"])
        XCTAssertTrue(removed.isEmpty, "a rename is not a removal")

        importer.apply(loaded: [], presentPaths: [])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<MeetingRecord>()), 0)
        XCTAssertEqual(removed, [Self.meetingID])
    }

    func test_apply_linksTheCoveringEntry() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let doc = try MeetingNotesDocument.decode(Self.sampleJSON())
        let entry = TimeEntry(title: "Roadmap planning", startAt: doc.startedAt, endAt: doc.endedAt)
        ctx.insert(entry)
        try ctx.save()

        let importer = MeetingImporter(modelContext: ctx)
        let folder = MeetingNotesArchive.Entry(folder: URL(fileURLWithPath: "/a/m"), modifiedAt: Date())
        importer.apply(loaded: [(folder, doc)], presentPaths: [folder.folder.path],
                       now: doc.startedAt.addingTimeInterval(7200))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingRecord>()).first?.linkedEntryID, entry.id)
    }
}
