import Foundation

enum DraftParser {
    private struct DraftJSON: Decodable {
        let title: String
        let role: String?
        let project: String?
        let customer: String?
        let rationale: String?
    }

    /// Extracts the first JSON object from model output and resolves role/project/customer
    /// against the catalog (case-insensitive name match). If the model named something
    /// we don't know, the field is set to nil.
    static func parse(_ text: String, context: SuggestionContext, providerLabel: String) throws -> EntryDraft {
        let body = extractJSON(from: text)
        guard let data = body.data(using: .utf8) else { throw AIError.parseFailed("no utf8") }
        let parsed: DraftJSON
        do {
            parsed = try JSONDecoder().decode(DraftJSON.self, from: data)
        } catch {
            throw AIError.parseFailed(body)
        }
        let role = resolveRole(parsed.role, in: context)
        let project = resolveProject(parsed.project, in: context)
        let customer = resolveCustomer(parsed.customer, in: context) ?? project?.customer
        return EntryDraft(
            title: parsed.title,
            role: role,
            project: project,
            customer: customer,
            rationale: parsed.rationale ?? providerLabel,
            raw: text
        )
    }

    private static func extractJSON(from s: String) -> String {
        guard let open = s.firstIndex(of: "{"),
              let close = s.lastIndex(of: "}"),
              open < close else { return s }
        return String(s[open...close])
    }

    private static func resolveRole(_ name: String?, in ctx: SuggestionContext) -> Role? {
        guard let name, !name.isEmpty else { return nil }
        let target = name.lowercased()
        return ctx.roles.first { $0.name.lowercased() == target }
    }
    private static func resolveProject(_ name: String?, in ctx: SuggestionContext) -> Project? {
        guard let name, !name.isEmpty else { return nil }
        let target = name.lowercased()
        return ctx.projects.first { $0.name.lowercased() == target }
    }
    private static func resolveCustomer(_ name: String?, in ctx: SuggestionContext) -> Customer? {
        guard let name, !name.isEmpty else { return nil }
        let target = name.lowercased()
        return ctx.customers.first { $0.name.lowercased() == target }
    }
}
