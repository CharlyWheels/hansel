import Foundation

/// Writes a meeting's corrected name back into Meeting Notes' archive.
///
/// Only the `title` of a finished meeting's `meeting.json` is changed; every other
/// field is kept as Meeting Notes wrote it. That is all Meeting Notes needs: its
/// meeting list reads the title from that file, and on launch it renames any folder
/// whose name no longer matches its title — regenerating `meeting.md` and
/// `transcript.md` and syncing — through its own rename. Hansel never renames
/// folders or renders notes itself, so it cannot get Meeting Notes' formats wrong.
///
/// Writing back is best effort and never throws. A file in a layout Hansel does not
/// recognise — a Meeting Notes update, a half-written file — is left exactly as it
/// is: the name is still changed in Hansel, and only Meeting Notes keeps its own.
enum MeetingNotesTitleWriter {

    static let enabledKey = "meetingNotes.writeTitles"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    enum Outcome: Equatable {
        case written
        case alreadyCurrent
        /// Left untouched; the reason is for the log.
        case notWritten(String)
    }

    static func write(title: String, toFolder folder: URL) -> Outcome {
        guard let stateURL = MeetingNotesArchive.stateFile(in: folder) else {
            return .notWritten("no meeting file")
        }
        guard let data = try? Data(contentsOf: stateURL) else { return .notWritten("unreadable") }

        // Only a layout Hansel fully understands is touched: a JSON object with a
        // string title, finished, that Hansel's own reader accepts.
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .notWritten("not a JSON object")
        }
        guard let current = object["title"] as? String else { return .notWritten("no title field") }
        guard object["status"] as? String == "complete" else { return .notWritten("not a finished meeting") }
        guard (try? MeetingNotesDocument.decode(data)) != nil else { return .notWritten("unrecognised layout") }
        if current == title { return .alreadyCurrent }

        object["title"] = title
        // The same formatting Meeting Notes' own encoder uses.
        guard let output = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return .notWritten("could not encode") }

        // Prove the rewrite changed the title and nothing else before replacing the
        // original, so an unexpected value type can never damage the file.
        guard var check = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any],
              check["title"] as? String == title,
              (try? MeetingNotesDocument.decode(output)) != nil else {
            return .notWritten("rewrite did not verify")
        }
        check["title"] = current
        guard NSDictionary(dictionary: check).isEqual(to: NSDictionary(dictionary: originalObject(data))) else {
            return .notWritten("rewrite would change other fields")
        }

        do {
            try output.write(to: stateURL, options: .atomic)
        } catch {
            return .notWritten(error.localizedDescription)
        }
        return .written
    }

    private static func originalObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
