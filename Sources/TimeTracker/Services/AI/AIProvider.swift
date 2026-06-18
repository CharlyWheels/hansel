import Foundation

/// Context passed to an AI provider to draft an entry. Built by `PromptBuilder`
/// using `SuggestionEngine`. User toggles which fields are actually sent via
/// `ContextFieldSelection` in the AI settings pane.
struct SuggestionContext {
    let windowStart: Date
    let windowEnd: Date
    let samples: [ActivitySample]
    let idleIntervals: [IdleInterval]
    let recentEntries: [TimeEntry]
    let projects: [Project]
    let customers: [Customer]
    let roles: [Role]
    let calendarEventTitle: String?
    let fields: ContextFieldSelection
    let ruleHints: RuleEngine.Hints
    /// Incomplete user-maintained todos. Pass roots only — `PromptBuilder`
    /// walks the `subtasks` relation to render the tree.
    let activeTodos: [Todo]
}

/// Parsed JSON output from an AI provider, with role/project/customer already resolved
/// against the catalog (or nil if the model named something we don't know).
struct EntryDraft {
    let title: String
    let role: Role?
    let project: Project?
    let customer: Customer?
    let rationale: String
    let raw: String
}

protocol AIProvider {
    var id: UUID { get }
    var displayName: String { get }
    func draft(_ context: SuggestionContext) async throws -> EntryDraft
}

struct ContextFieldSelection: Codable, Equatable {
    var includeAppSamples: Bool = true
    var includeBrowserURLs: Bool = true
    var includeCalendarTitle: Bool = true
    var includeRecentEntries: Bool = true
    var includeCatalog: Bool = true
    var includeTimeOfDay: Bool = false
    var includeDayOfWeek: Bool = false
}

enum AIError: LocalizedError {
    case noProviderConfigured
    case badStatus(Int, String)
    case emptyResponse
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured: return "No AI provider is configured. Open Settings → AI."
        case .badStatus(let code, let body): return "AI provider returned HTTP \(code): \(body)"
        case .emptyResponse: return "AI provider returned an empty response."
        case .parseFailed(let s): return "Could not parse AI response: \(s)"
        }
    }
}
