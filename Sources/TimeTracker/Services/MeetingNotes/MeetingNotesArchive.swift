import Foundation

/// Finds and reads the Meeting Notes archive: `YYYY/MM/DD/<meeting>/.meeting.json`.
enum MeetingNotesArchive {
    static let stateFileName = ".meeting.json"
    static let notesFileName = "meeting.md"
    static let transcriptFileName = "transcript.md"

    /// Meeting Notes' own default, used when neither app has a path configured.
    static let defaultPath = "~/Documents/Meetings Notes"

    /// Hansel's setting, when the user chose a folder; empty means "follow Meeting Notes".
    static let pathDefaultsKey = "meetingNotes.archivePath"

    /// Where Meeting Notes keeps its archive path (`ArchiveSettingsStore` in that app).
    private static let meetingNotesDomain = "app.meetingnotes.menu"
    private static let meetingNotesPathKey = "archive.localPath"

    /// Hansel's setting first, then whatever Meeting Notes is configured to use, then
    /// its default, so a moved archive is followed without touching Hansel's settings.
    static func resolvedRoot(defaults: UserDefaults = .standard) -> URL {
        let own = defaults.string(forKey: pathDefaultsKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        let theirs = UserDefaults(suiteName: meetingNotesDomain)?.string(forKey: meetingNotesPathKey) ?? ""
        let path = !own.isEmpty ? own : (!theirs.isEmpty ? theirs : defaultPath)
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    struct Entry: Equatable {
        let folder: URL
        let modifiedAt: Date
        var stateFile: URL { folder.appending(path: MeetingNotesArchive.stateFileName) }
    }

    /// Every meeting folder under `root`. Only the date levels are walked, so a large
    /// archive costs a few directory listings, not a crawl of every transcript.
    static func scan(root: URL, fileManager: FileManager = .default) -> [Entry] {
        var entries: [Entry] = []
        for year in subdirectories(of: root, fileManager) where isNumber(year.lastPathComponent, length: 4) {
            for month in subdirectories(of: year, fileManager) where isNumber(month.lastPathComponent, length: 2) {
                for day in subdirectories(of: month, fileManager) where isNumber(day.lastPathComponent, length: 2) {
                    for meeting in subdirectories(of: day, fileManager) {
                        let state = meeting.appending(path: stateFileName)
                        guard let attrs = try? fileManager.attributesOfItem(atPath: state.path),
                              let modified = attrs[.modificationDate] as? Date else { continue }
                        entries.append(Entry(folder: meeting, modifiedAt: modified))
                    }
                }
            }
        }
        return entries
    }

    static func load(_ folder: URL) throws -> MeetingNotesDocument {
        let data = try Data(contentsOf: folder.appending(path: stateFileName))
        return try MeetingNotesDocument.decode(data)
    }

    private static func subdirectories(of url: URL, _ fm: FileManager) -> [URL] {
        let items = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func isNumber(_ s: String, length: Int) -> Bool {
        s.count == length && s.allSatisfy(\.isNumber)
    }
}
