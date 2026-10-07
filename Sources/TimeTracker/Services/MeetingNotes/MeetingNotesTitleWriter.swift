import Foundation

/// Writes a meeting's corrected name back into Meeting Notes' archive.
///
/// Only the `title` of a finished meeting's `meeting.json` is changed; every other
/// field is kept as Meeting Notes wrote it. That is all Meeting Notes needs: its
/// meeting list reads the title from that file, and on launch it renames any folder
/// whose name no longer matches its title — regenerating `meeting.md` and
/// `transcript.md` and syncing — through its own rename. Hansel never renames
/// folders or renders notes itself, so it cannot get Meeting Notes' formats wrong.
enum MeetingNotesTitleWriter {

    static let enabledKey = "meetingNotes.writeTitles"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    enum Outcome: Equatable {
        case written
        case alreadyCurrent
        /// Missing file, or a meeting Meeting Notes is still working on.
        case skipped
    }

    static func write(title: String, toFolder folder: URL) throws -> Outcome {
        guard let stateURL = MeetingNotesArchive.stateFile(in: folder) else { return .skipped }
        let data = try Data(contentsOf: stateURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: stateURL.path])
        }
        // A meeting still recording or processing is Meeting Notes' to write.
        guard (object["status"] as? String ?? "complete") == "complete" else { return .skipped }
        if object["title"] as? String == title { return .alreadyCurrent }
        object["title"] = title
        // The same formatting Meeting Notes' own encoder uses.
        let output = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try output.write(to: stateURL, options: .atomic)
        return .written
    }
}
