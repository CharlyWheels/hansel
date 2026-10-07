import Foundation

/// Finds and reads the Meeting Notes archive.
///
/// Meeting Notes has used more than one layout, so both are read:
/// - `YYYY/MM/DD/<meeting>/.meeting.json`
/// - `YYYY/Www/YYYY-MM-DD/<meeting>/meeting.json` (by ISO week; current versions)
/// Only expecting the first made every meeting from current versions invisible.
enum MeetingNotesArchive {
    /// State file names, newest layout first.
    static let stateFileNames = ["meeting.json", ".meeting.json"]
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
    }

    /// The meeting's state file, whichever layout wrote it.
    static func stateFile(in folder: URL, fileManager: FileManager = .default) -> URL? {
        stateFileNames
            .map { folder.appending(path: $0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Every meeting folder under `root`: a folder holding a state file, at most three
    /// levels below a year folder. Recordings and transcripts are never opened, so a
    /// large archive costs a few directory listings.
    static func scan(root: URL, fileManager: FileManager = .default) -> [Entry] {
        var entries: [Entry] = []
        func walk(_ folder: URL, depth: Int) {
            for child in subdirectories(of: folder, fileManager) {
                if let state = stateFile(in: child, fileManager: fileManager) {
                    guard let attrs = try? fileManager.attributesOfItem(atPath: state.path),
                          let modified = attrs[.modificationDate] as? Date else { continue }
                    entries.append(Entry(folder: child, modifiedAt: modified))
                } else if depth < 3 {
                    walk(child, depth: depth + 1)
                }
            }
        }
        for year in subdirectories(of: root, fileManager) where isNumber(year.lastPathComponent, length: 4) {
            walk(year, depth: 1)
        }
        return entries.sorted { $0.folder.path < $1.folder.path }
    }

    static func load(_ folder: URL) throws -> MeetingNotesDocument {
        guard let state = stateFile(in: folder) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        return try MeetingNotesDocument.decode(try Data(contentsOf: state))
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
