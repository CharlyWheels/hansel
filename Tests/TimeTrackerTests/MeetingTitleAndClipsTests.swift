import XCTest
import SwiftData
@testable import TimeTracker

@MainActor
final class MeetingTitleSyncTests: XCTestCase {

    private func importMeeting(
        title: String = "Review Lulu apps", entry: TimeEntry, ctx: ModelContext
    ) throws -> (MeetingImporter, MeetingNotesArchive.Entry, MeetingNotesDocument) {
        let doc = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON(title: title))
        entry.startAt = doc.startedAt
        entry.endAt = doc.endedAt
        ctx.insert(entry)
        try ctx.save()
        let importer = MeetingImporter(modelContext: ctx)
        let folder = MeetingNotesArchive.Entry(folder: URL(fileURLWithPath: "/a/m"), modifiedAt: Date())
        importer.apply(loaded: [(folder, doc)], presentPaths: [folder.folder.path],
                       now: doc.startedAt.addingTimeInterval(7200))
        return (importer, folder, doc)
    }

    func test_editingTheEntryRenamesItsMeeting() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let entry = TimeEntry(title: "Review Lulu apps")
        _ = try importMeeting(entry: entry, ctx: ctx)

        entry.title = "Solution Engineers Meeting"
        MeetingTitleSync.entrySaved(entry, context: ctx)
        let record = try XCTUnwrap(ctx.fetch(FetchDescriptor<MeetingRecord>()).first)
        XCTAssertEqual(record.title, "Solution Engineers Meeting")
        XCTAssertTrue(record.titleIsUserSet)
    }

    func test_reReadingMeetingNotesKeepsTheUsersName() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let entry = TimeEntry(title: "Review Lulu apps")
        let (importer, folder, doc) = try importMeeting(entry: entry, ctx: ctx)
        entry.title = "Solution Engineers Meeting"
        MeetingTitleSync.entrySaved(entry, context: ctx)

        let changed = MeetingNotesArchive.Entry(folder: folder.folder, modifiedAt: Date().addingTimeInterval(60))
        importer.apply(loaded: [(changed, doc)], presentPaths: [folder.folder.path],
                       now: doc.startedAt.addingTimeInterval(7200))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingRecord>()).first?.title, "Solution Engineers Meeting")
    }

    func test_aConfirmedEntryNamesItsMeetingWhenLinked() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let entry = TimeEntry(title: "Solution Engineers Meeting", isHumanConfirmed: true)
        _ = try importMeeting(entry: entry, ctx: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingRecord>()).first?.title, "Solution Engineers Meeting")
    }

    func test_anAutomaticEntryDoesNotRenameTheMeeting() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let entry = TimeEntry(title: "Something the AI guessed", isHumanConfirmed: false)
        _ = try importMeeting(entry: entry, ctx: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingRecord>()).first?.title, "Review Lulu apps")
    }
}

final class SpeakerClipsTests: XCTestCase {

    private func seg(_ track: String, _ cluster: String, _ start: Double, _ end: Double) -> SpeakerTimeline.Segment {
        SpeakerTimeline.Segment(track: track, start: start, end: end, cluster: cluster)
    }

    func test_picksThisVoicesOwnPhrasesSpreadOverTheMeeting() {
        let segments = [
            seg("system", "S1", 10, 16), seg("system", "S1", 20, 26),   // same exchange
            seg("system", "S1", 200, 206), seg("system", "S1", 500, 506),
            seg("system", "S2", 300, 306),
        ]
        let clips = SpeakerClips.samples(track: "system", cluster: "S1", segments: segments, lines: [])
        XCTAssertEqual(clips.count, 3)
        XCTAssertTrue(clips.allSatisfy { $0.track == "system" })
        let starts = clips.map(\.start)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= SpeakerClips.minimumGap })
    }

    func test_skipsMomentsSomeoneElseTalksOverAndTooShortOnes() {
        let segments = [
            seg("microphone", "S1", 0, 6), seg("microphone", "S2", 1, 5),  // talked over
            seg("microphone", "S1", 100, 101),                               // too short
            seg("microphone", "S1", 300, 330),                               // long: capped
        ]
        let clips = SpeakerClips.samples(track: "microphone", cluster: "S1", segments: segments, lines: [])
        XCTAssertEqual(clips.map(\.start), [300])
        XCTAssertEqual(clips.first?.duration, SpeakerClips.maximumSeconds)
    }

    func test_textJoinsTheTranscriptPiecesInsideTheClip() {
        let lines = [
            SpeakerClips.Line(track: "system", start: 9.9, end: 11.0, text: "so it's"),
            SpeakerClips.Line(track: "system", start: 11.0, end: 12.1, text: "looking at"),
            SpeakerClips.Line(track: "microphone", start: 11.0, end: 12.1, text: "not me"),
            SpeakerClips.Line(track: "system", start: 30, end: 31, text: "later"),
        ]
        let clips = SpeakerClips.samples(track: "system", cluster: "S1",
                                         segments: [seg("system", "S1", 10, 15)], lines: lines)
        XCTAssertEqual(clips.first?.text, "so it's looking at")
    }

    func test_unknownVoiceHasNoSamples() {
        XCTAssertTrue(SpeakerClips.samples(track: "system", cluster: "S9",
                                           segments: [seg("system", "S1", 0, 6)], lines: []).isEmpty)
    }
}

final class MeetingNotesTitleWriterTests: XCTestCase {

    private func folder(with json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url.appending(path: "meeting.json"))
        return url
    }

    private func json(at folder: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appending(path: "meeting.json"))) as? [String: Any])
    }

    func test_changesOnlyTheTitleAndKeepsEverythingElse() throws {
        let url = try folder(with: """
        {"id":"36FD4896-DFCB-46C2-AB5C-4014D4EB94FF","status":"complete","title":"Review Lulu apps",
         "startedAt":"2026-10-07T13:28:40Z","transcriptionVersion":1,
         "insights":{"topics":[{"title":"Keep me"}]},
         "transcript":[{"start":4.4799999999999995,"end":5.6,"text":"a/b","speaker":"Unknown"}]}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try MeetingNotesTitleWriter.write(title: "Solution Engineers Meeting", toFolder: url), .written)

        let object = try json(at: url)
        XCTAssertEqual(object["title"] as? String, "Solution Engineers Meeting")
        XCTAssertEqual(object["startedAt"] as? String, "2026-10-07T13:28:40Z")
        XCTAssertEqual(object["transcriptionVersion"] as? Int, 1)
        let topics = (object["insights"] as? [String: Any])?["topics"] as? [[String: Any]]
        XCTAssertEqual(topics?.first?["title"] as? String, "Keep me", "nested titles are untouched")
        let turn = (object["transcript"] as? [[String: Any]])?.first
        XCTAssertEqual(turn?["start"] as? Double, 4.4799999999999995)
        XCTAssertEqual(turn?["text"] as? String, "a/b")

        // The result still decodes the way Hansel (and Meeting Notes) read it.
        XCTAssertEqual(try MeetingNotesArchive.load(url).title, "Solution Engineers Meeting")
        XCTAssertEqual(try MeetingNotesTitleWriter.write(title: "Solution Engineers Meeting", toFolder: url), .alreadyCurrent)
    }

    func test_neverTouchesAMeetingStillInProgress() throws {
        let url = try folder(with: #"{"status":"recording","title":"Live"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try MeetingNotesTitleWriter.write(title: "Other", toFolder: url), .skipped)
        XCTAssertEqual(try json(at: url)["title"] as? String, "Live")
    }
}
