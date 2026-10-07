import Foundation

/// A Meeting Notes recording in progress.
struct ActiveRecording: Equatable, Sendable {
    /// Folder name without the time prefix and id suffix, e.g. "meet-up-lp".
    let slug: String
    /// When the recording began: Meeting Notes creates the folder as it starts.
    let startedAt: Date
    let folderName: String

    /// Best-effort readable title when no calendar event matches the slug.
    var fallbackTitle: String {
        let words = slug.split(separator: "-").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// Spots a recording that Meeting Notes has started but not finished.
///
/// Meeting Notes creates `HHMM-<title-slug>-<ID>` the moment recording starts and only
/// writes `meeting.json` once it stops, so a fresh folder without a state file is a
/// recording in progress — and its slug is the calendar event's title. That is the
/// most precise "which meeting am I in" signal available: when two events overlap,
/// the user picked the right one when they pressed Record.
enum MeetingRecordingProbe {

    static let bundleId = "app.meetingnotes.menu"
    /// A folder older than this without a state file is an abandoned recording.
    static let maxRecordingAge: TimeInterval = 4 * 3600

    static func activeRecording(
        root: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> ActiveRecording? {
        let newest = dayFolders(root: root, now: now)
            .flatMap { subfolders(of: $0, fileManager) }
            .compactMap { folder -> (URL, Date)? in
                guard let created = creationDate(of: folder, fileManager) else { return nil }
                return (folder, created)
            }
            .max { $0.1 < $1.1 }
        // Only the newest folder can be the one recording: an older one without a
        // state file was abandoned before a later recording began.
        guard let (folder, created) = newest,
              now.timeIntervalSince(created) < maxRecordingAge,
              MeetingNotesArchive.stateFile(in: folder, fileManager: fileManager) == nil,
              let slug = slug(fromFolderName: folder.lastPathComponent) else { return nil }
        return ActiveRecording(slug: slug, startedAt: created, folderName: folder.lastPathComponent)
    }

    /// "1602-meet-up-lp-797AA51A" → "meet-up-lp".
    static func slug(fromFolderName name: String) -> String? {
        var parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 3,
              parts.first?.count == 4, parts.first?.allSatisfy(\.isNumber) == true,
              parts.last?.count == 8, parts.last?.allSatisfy(\.isHexDigit) == true else { return nil }
        parts.removeFirst()
        parts.removeLast()
        return parts.joined(separator: "-")
    }

    /// The same slug Meeting Notes derives from an event title: "CR <> SS" → "cr-ss".
    static func slugify(_ title: String) -> String {
        let lowered = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        let mapped = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    /// Today's and yesterday's day folders, in both archive layouts.
    static func dayFolders(root: URL, now: Date) -> [URL] {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = .current
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = .current
        return [now, now.addingTimeInterval(-86_400)].flatMap { day -> [URL] in
            let c = greg.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { return [] }
            let week = iso.component(.weekOfYear, from: day)
            let weekYear = iso.component(.yearForWeekOfYear, from: day)
            return [
                root.appending(path: String(format: "%04d/W%02d/%04d-%02d-%02d", weekYear, week, y, m, d)),
                root.appending(path: String(format: "%04d/%02d/%02d", y, m, d)),
            ]
        }
    }

    private static func subfolders(of url: URL, _ fm: FileManager) -> [URL] {
        let items = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func creationDate(of url: URL, _ fm: FileManager) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }
}
