import Foundation

/// Parses a boundary verdict and refuses to take the model's timestamp on trust.
enum BoundaryParser {

    private struct VerdictJSON: Decodable {
        let same_task: Bool?
        let boundary_at: String?
        let title: String?
        let role: String?
        let project: String?
        let customer: String?
        let todo: String?
        let confidence: Double?
        let rationale: String?
    }

    static func parse(
        _ text: String,
        context: BoundaryContext,
        providerLabel: String
    ) throws -> BoundaryVerdict {
        let body = extractJSON(from: text)
        guard let data = body.data(using: .utf8) else { throw AIError.parseFailed("no utf8") }
        guard let parsed = try? JSONDecoder().decode(VerdictJSON.self, from: data) else {
            throw AIError.parseFailed(body)
        }

        // Absent `same_task` is treated as "no change": the safe default is to leave
        // the user's tracking alone rather than act on a malformed answer.
        let sameTask = parsed.same_task ?? true

        return BoundaryVerdict(
            sameTask: sameTask,
            boundaryAt: sameTask ? nil : clampBoundary(parsed.boundary_at, context: context),
            title: nonEmpty(parsed.title),
            role: nonEmpty(parsed.role),
            project: nonEmpty(parsed.project),
            customer: nonEmpty(parsed.customer),
            todo: nonEmpty(parsed.todo),
            confidence: Similarity.clamp01(parsed.confidence ?? 0),
            rationale: nonEmpty(parsed.rationale) ?? providerLabel,
            raw: text
        )
    }

    /// The model may *refine* the machine's boundary; it may not invent one.
    ///
    /// Models state timestamps with complete confidence and frequently get them wrong —
    /// a fabricated boundary hours in the past would silently rewrite a whole day. An
    /// unparseable or out-of-range answer falls back to the segmenter's own instant,
    /// which is always defensible because it came from observed evidence.
    private static func clampBoundary(_ raw: String?, context: BoundaryContext) -> Date {
        guard let raw, let parsed = parseDate(raw) else { return context.boundaryAt }
        return min(max(parsed, context.earliestAllowed), context.latestAllowed)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        if let date = isoWithFractional.date(from: trimmed) { return date }
        if let date = iso.date(from: trimmed) { return date }
        return nil
    }

    /// Takes the outermost brace pair. Models wrap JSON in prose and fences often
    /// enough that being lenient here is worth more than being strict.
    private static func extractJSON(from text: String) -> String {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open < close else { return text }
        return String(text[open...close])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return trimmed
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
