import Foundation

enum DraftParser {
    private struct DraftJSON: Decodable {
        let title: String
        let role: String?
        let project: String?
        let customer: String?
        let todo: String?
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
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AIError.parseFailed("empty title") }
        let role = resolveRole(parsed.role, in: context)
        let project = resolveProject(parsed.project, in: context)
        let customer = resolveCustomer(parsed.customer, in: context) ?? project?.customer
        let todo = resolveTodo(parsed.todo, in: context)
        return EntryDraft(
            title: title,
            role: role,
            project: project,
            customer: customer,
            todo: todo,
            rationale: parsed.rationale ?? providerLabel,
            raw: text
        )
    }

    private static func extractJSON(from s: String) -> String {
        PromptText.firstJSONObject(in: s) ?? s
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

    /// Resolves the model's todo reference, preferring the short id it was given.
    ///
    /// Falls back to an exact breadcrumb or title match for models that echo the text
    /// instead of the id. An ambiguous title resolves to nil rather than a guess — a
    /// missing link costs nothing, a wrong one silently mis-files the entry.
    private static func resolveTodo(_ key: String?, in ctx: SuggestionContext) -> Todo? {
        guard let raw = key?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != "null" else { return nil }

        let indexed = PromptBuilder.flattenTodos(roots: ctx.activeTodos)
        if let hit = indexed.first(where: { $0.key.caseInsensitiveCompare(raw) == .orderedSame }) {
            return hit.todo
        }
        let byPath = indexed.filter {
            $0.todo.breadcrumbPath.caseInsensitiveCompare(raw) == .orderedSame
        }
        if byPath.count == 1 { return byPath[0].todo }
        let byTitle = indexed.filter { $0.todo.title.caseInsensitiveCompare(raw) == .orderedSame }
        return byTitle.count == 1 ? byTitle[0].todo : nil
    }
}
