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

    private func folder(with data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: url.appending(path: "meeting.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func folder(with json: String) throws -> URL { try folder(with: Data(json.utf8)) }

    private func fileData(_ folder: URL) throws -> Data {
        try Data(contentsOf: folder.appending(path: "meeting.json"))
    }

    func test_changesOnlyTheTitleAndKeepsEverythingElse() throws {
        let original = MeetingNotesImportTests.sampleJSON(title: "Review Lulu apps")
        let url = try folder(with: original)
        XCTAssertEqual(MeetingNotesTitleWriter.write(title: "Solution Engineers Meeting", toFolder: url), .written)

        var after = try XCTUnwrap(JSONSerialization.jsonObject(with: fileData(url)) as? [String: Any])
        XCTAssertEqual(after["title"] as? String, "Solution Engineers Meeting")
        after["title"] = "Review Lulu apps"
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: before))
        XCTAssertEqual(try MeetingNotesArchive.load(url).title, "Solution Engineers Meeting")
        XCTAssertEqual(MeetingNotesTitleWriter.write(title: "Solution Engineers Meeting", toFolder: url), .alreadyCurrent)
    }

    /// Whatever the file looks like, writing never throws and never alters a file it
    /// does not fully understand.
    func test_unexpectedFilesAreLeftByteForByteUntouched() throws {
        let cases: [String] = [
            "",                                                     // empty
            "{ not json",                                           // truncated
            "[1, 2, 3]",                                            // not an object
            #"{"status":"complete","name":"Renamed field"}"#,      // title moved
            #"{"status":"complete","title":42}"#,                  // title not a string
            #"{"title":"Live","status":"recording"}"#,             // still recording
            #"{"title":"No status"}"#,                              // status missing
            #"{"title":"New layout","status":"complete","meeting":{}}"#,  // unrecognised layout
        ]
        for json in cases {
            let url = try folder(with: json)
            let outcome = MeetingNotesTitleWriter.write(title: "Other", toFolder: url)
            guard case .notWritten = outcome else { return XCTFail("\(json): \(outcome)") }
            XCTAssertEqual(try fileData(url), Data(json.utf8), json)
        }
        let empty = FileManager.default.temporaryDirectory.appending(path: "mn-none-\(UUID().uuidString)")
        guard case .notWritten = MeetingNotesTitleWriter.write(title: "x", toFolder: empty) else {
            return XCTFail("a missing file is not written")
        }
    }
}

@MainActor
final class MeetingTitleResilienceTests: XCTestCase {

    func test_renamingInHanselWorksWhenMeetingNotesFileIsBroken() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let url = FileManager.default.temporaryDirectory.appending(path: "mn-broken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ broken".utf8).write(to: url.appending(path: "meeting.json"))

        let entry = TimeEntry(title: "Review Lulu apps")
        ctx.insert(entry)
        let record = MeetingRecord(id: UUID(), title: "Review Lulu apps", startedAt: Date(),
                                   folderPath: url.path, fileModifiedAt: Date())
        record.linkedEntryID = entry.id
        ctx.insert(record)
        try ctx.save()

        entry.title = "Solution Engineers Meeting"
        MeetingTitleSync.entrySaved(entry, context: ctx)
        XCTAssertEqual(record.title, "Solution Engineers Meeting", "Hansel's name changes regardless")
        XCTAssertFalse(record.titleWrittenToNotes)
        XCTAssertEqual(try Data(contentsOf: url.appending(path: "meeting.json")), Data("{ broken".utf8))
    }

    func test_anEmptyTitleFromMeetingNotesNeverReplacesTheUsersName() throws {
        let doc = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON(title: ""))
        let record = MeetingRecord(id: doc.id, title: "Solution Engineers Meeting", startedAt: doc.startedAt,
                                   folderPath: "/a/m", fileModifiedAt: Date())
        record.titleIsUserSet = true
        record.titleWrittenToNotes = true
        MeetingImporter.update(record, from: doc,
                               entry: MeetingNotesArchive.Entry(folder: URL(fileURLWithPath: "/a/m"), modifiedAt: Date()))
        XCTAssertEqual(record.title, "Solution Engineers Meeting")
    }
}

@MainActor
final class MeetingTitleFollowsEntryTests: XCTestCase {

    private var container: ModelContainer!
    private var ctx: ModelContext { container.mainContext }
    private var doc: MeetingNotesDocument!
    private var importer: MeetingImporter!
    private let folder = MeetingNotesArchive.Entry(folder: URL(fileURLWithPath: "/a/m"), modifiedAt: Date())

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
        doc = try MeetingNotesDocument.decode(MeetingNotesImportTests.sampleJSON(title: "CR <> SS"))
        importer = MeetingImporter(modelContext: ctx)
        UserDefaults.standard.set(false, forKey: MeetingNotesTitleWriter.enabledKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: MeetingNotesTitleWriter.enabledKey)
    }

    private func scan() {
        importer.apply(loaded: [(folder, doc)], presentPaths: [folder.folder.path],
                       now: doc.startedAt.addingTimeInterval(7200))
    }

    private var record: MeetingRecord { try! XCTUnwrap(ctx.fetch(FetchDescriptor<MeetingRecord>()).first) }

    func test_splittingTheEntryMovesTheMeetingToThePartThatCoversIt() throws {
        // One confirmed entry covering this meeting and the one before.
        let wide = TimeEntry(title: "Solution Engineer Meeting",
                             startAt: doc.startedAt.addingTimeInterval(-1800), endAt: doc.endedAt,
                             isHumanConfirmed: true)
        ctx.insert(wide)
        try ctx.save()
        scan()
        XCTAssertEqual(record.title, "Solution Engineer Meeting")

        // The user splits it: the part covering this meeting is "CR <> SS".
        wide.endAt = doc.startedAt
        let part = TimeEntry(title: "CR <> SS", startAt: doc.startedAt, endAt: doc.endedAt, isHumanConfirmed: true)
        ctx.insert(part)
        try ctx.save()
        scan()
        XCTAssertEqual(record.linkedEntryID, part.id)
        XCTAssertEqual(record.title, "CR <> SS")
    }

    func test_renameOnTheMeetingPageSurvivesScansUntilTheEntryChanges() throws {
        let entry = TimeEntry(title: "CR <> SS", startAt: doc.startedAt, endAt: doc.endedAt, isHumanConfirmed: true)
        ctx.insert(entry)
        try ctx.save()
        scan()

        MeetingTitleSync.rename(record, to: "Carlos / Sasha catch-up", context: ctx)
        scan()
        XCTAssertEqual(record.title, "Carlos / Sasha catch-up")

        entry.title = "Sasha 1:1"
        MeetingTitleSync.entrySaved(entry, context: ctx)
        XCTAssertEqual(record.title, "Sasha 1:1")
    }

    func test_reSavingAnUnchangedEntryKeepsAManualRename() throws {
        let entry = TimeEntry(title: "CR <> SS", startAt: doc.startedAt, endAt: doc.endedAt, isHumanConfirmed: true)
        ctx.insert(entry)
        try ctx.save()
        scan()
        MeetingTitleSync.rename(record, to: "Catch-up", context: ctx)
        MeetingTitleSync.entrySaved(entry, context: ctx)
        XCTAssertEqual(record.title, "Catch-up")
    }
}
