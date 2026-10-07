import Foundation
import Observation
import SwiftData

/// Keeps `MeetingRecord`s in step with the Meeting Notes archive.
///
/// Polls rather than watching the file system: meetings arrive a few times a day, a scan
/// is a handful of directory listings, and only files whose modification date changed
/// are decoded.
@Observable
@MainActor
final class MeetingImporter {
    static let enabledKey = "meetingNotes.importEnabled"
    static let scanInterval: TimeInterval = 120

    private(set) var lastScanAt: Date?
    private(set) var lastError: String?
    private(set) var isScanning = false

    /// Called for each meeting that is new or whose file changed, after it was saved.
    @ObservationIgnored var onImported: ((MeetingRecord, MeetingNotesDocument) -> Void)?
    /// Called with the ids of meetings that disappeared from the archive.
    @ObservationIgnored var onRemoved: (([UUID]) -> Void)?
    /// Called after every completed scan, for work that retries on a schedule.
    @ObservationIgnored var onScanFinished: (() -> Void)?

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let rootProvider: () -> URL

    init(modelContext: ModelContext, rootProvider: @escaping () -> URL = { MeetingNotesArchive.resolvedRoot() }) {
        self.modelContext = modelContext
        self.rootProvider = rootProvider
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func start() {
        Task { await scan() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
    }

    func scan(now: Date = Date()) async {
        guard Self.isEnabled, !isScanning else { return }
        isScanning = true
        defer { isScanning = false; lastScanAt = now }

        let root = rootProvider()
        guard FileManager.default.fileExists(atPath: root.path) else {
            // Not an error worth deleting anything over: the folder may just not exist
            // yet (no meeting recorded) or sit on a volume that is not mounted.
            lastError = "Archive folder not found: \(root.path)"
            return
        }
        lastError = nil

        let records = (try? modelContext.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        let known = Dictionary(records.map { ($0.folderPath, $0.fileModifiedAt) }, uniquingKeysWith: { a, _ in a })

        // Listing and decoding run off the main actor; a first import can be dozens of
        // transcripts.
        let result = await Task.detached(priority: .utility) {
            let entries = MeetingNotesArchive.scan(root: root)
            var loaded: [(MeetingNotesArchive.Entry, MeetingNotesDocument)] = []
            var failures = 0
            for entry in entries {
                if let seen = known[entry.folder.path], entry.modifiedAt.timeIntervalSince(seen) < 1 { continue }
                do { loaded.append((entry, try MeetingNotesArchive.load(entry.folder))) }
                catch { failures += 1 }
            }
            return (paths: Set(entries.map(\.folder.path)), loaded: loaded, failures: failures)
        }.value

        apply(loaded: result.loaded, presentPaths: result.paths, now: now)
        onScanFinished?()
        if result.failures > 0 {
            lastError = "\(result.failures) meeting file(s) could not be read"
            AppLogger.log("meetings", level: .error, "decode_failed count=\(result.failures)")
        }
    }

    /// Saves what was read and removes meetings that left the archive. Split from
    /// `scan` so tests can drive it without a folder.
    func apply(loaded: [(MeetingNotesArchive.Entry, MeetingNotesDocument)], presentPaths: Set<String>, now: Date = Date()) {
        var records = (try? modelContext.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        var imported: [(MeetingRecord, MeetingNotesDocument)] = []

        for (entry, doc) in loaded where Self.isFinished(doc) {
            let record: MeetingRecord
            if let existing = records.first(where: { $0.id == doc.id }) {
                record = existing
            } else {
                record = MeetingRecord(id: doc.id, title: doc.title, startedAt: doc.startedAt,
                                       folderPath: entry.folder.path, fileModifiedAt: entry.modifiedAt,
                                       importedAt: now)
                modelContext.insert(record)
                records.append(record)
            }
            Self.update(record, from: doc, entry: entry)
            imported.append((record, doc))
        }

        // A renamed meeting moved folder but kept its id, so it was updated above; only
        // records whose folder is gone and was not re-found are removals.
        let removed = records.filter { !presentPaths.contains($0.folderPath) }
        let removedIDs = removed.map(\.id)
        for record in removed { modelContext.delete(record) }

        linkEntries(records: records.filter { !removedIDs.contains($0.id) }, now: now)
        try? modelContext.save()

        if !removedIDs.isEmpty { onRemoved?(removedIDs) }
        for (record, doc) in imported { onImported?(record, doc) }
        if !imported.isEmpty || !removedIDs.isEmpty {
            AppLogger.log("meetings", level: .info, "imported=\(imported.count) removed=\(removedIDs.count)")
        }
    }

    /// Meetings still being captured live in Meeting Notes' private spool, not the
    /// archive, but a status check costs nothing.
    static func isFinished(_ doc: MeetingNotesDocument) -> Bool {
        guard let status = doc.status else { return true }
        return status == "complete" || status == "failed"
    }

    static func update(_ record: MeetingRecord, from doc: MeetingNotesDocument, entry: MeetingNotesArchive.Entry) {
        if !record.titleIsUserSet { record.title = doc.title }
        record.startedAt = doc.startedAt
        record.endedAt = doc.endedAt
        record.status = doc.status ?? "complete"
        record.eventIdentifier = doc.calendar?.eventIdentifier
        record.folderPath = entry.folder.path
        record.fileModifiedAt = entry.modifiedAt
        record.summary = doc.insights?.summary ?? ""
        record.participantNames = doc.participants.compactMap { $0.name ?? $0.email }
        record.participantEmails = doc.participants.compactMap(\.email)
        record.actionItemCount = doc.actionItems.count
        record.hasTranscript = !doc.transcript.isEmpty
    }

    /// Re-links recent meetings on every scan. Entries are often confirmed, split or
    /// moved after the meeting, so a link made at import time can go stale; two weeks
    /// back is where corrections stop.
    private func linkEntries(records: [MeetingRecord], now: Date) {
        let horizon = now.addingTimeInterval(-14 * 86_400)
        let unlinked = records.filter { $0.startedAt >= horizon }
        guard let earliest = unlinked.map(\.startedAt).min() else { return }
        let from = earliest.addingTimeInterval(-12 * 3600)
        let entries = (try? modelContext.fetch(FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startAt >= from }
        ))) ?? []
        for record in unlinked {
            let entry = MeetingContextResolver.bestEntry(
                start: record.startedAt, end: record.endedAt, entries: entries, now: now
            )
            record.linkedEntryID = entry?.id
            if let entry { MeetingTitleSync.adoptConfirmedTitle(of: entry, into: record) }
        }
    }
}
