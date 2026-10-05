import Foundation

/// Turns window titles and URLs into comparable token sets.
///
/// Window titles are the richest signal the app collects — they carry the document,
/// ticket or customer name — but they are also full of chrome ("Untitled", "Google
/// Chrome", "— Edited") that is identical across unrelated tasks and would mask real
/// topic changes. The stoplist is what makes the topic delta meaningful.
enum TitleTokenizer {

    /// Window chrome and app furniture: present in unrelated titles, carries no topic.
    static let stopwords: Set<String> = [
        "untitled", "window", "new", "tab", "document", "documents", "file",
        "edited", "private", "browsing", "inbox", "home", "dashboard", "loading",
        "google", "chrome", "safari", "firefox", "arc", "edge", "brave",
        "com", "www", "http", "https", "the", "and", "for", "with",
    ]

    static let minimumTokenLength = 3
    static let maximumTokensPerSample = 12

    /// Lowercase, split on non-alphanumerics, drop chrome, numerals and short tokens.
    static func tokens(from title: String?) -> [String] {
        guard let title, !title.isEmpty else { return [] }
        let parts = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        var seen = Set<String>()
        var out: [String] = []
        for part in parts {
            guard part.count >= minimumTokenLength else { continue }
            guard !stopwords.contains(part) else { continue }
            // Pure numerals are usually counters, dates or ids that churn constantly.
            guard !part.allSatisfy(\.isNumber) else { continue }
            guard seen.insert(part).inserted else { continue }
            out.append(part)
            if out.count >= maximumTokensPerSample { break }
        }
        return out
    }

    /// Host plus first path component, e.g. `acme.atlassian.net/browse`.
    ///
    /// The first path segment is included deliberately: for SaaS tools the host alone
    /// is constant across every project ("github.com"), while the first segment
    /// usually carries the identity ("github.com/acme").
    static func hostKey(from url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        // A document open in an editor: the folder it lives in is the closest thing to
        // a "site" — usually the project or repo.
        if let parsed = URL(string: url), parsed.isFileURL {
            let folder = parsed.deletingLastPathComponent().lastPathComponent.lowercased()
            return folder.isEmpty || folder == "/" ? nil : "file:\(folder)"
        }
        guard let parsed = URL(string: url), let host = parsed.host, !host.isEmpty else {
            return nil
        }
        let cleanHost = host.lowercased().hasPrefix("www.")
            ? String(host.lowercased().dropFirst(4))
            : host.lowercased()
        let firstSegment = parsed.pathComponents
            .first { $0 != "/" && !$0.isEmpty }
        guard let firstSegment, !firstSegment.isEmpty else { return cleanHost }
        return "\(cleanHost)/\(firstSegment.lowercased())"
    }
}
