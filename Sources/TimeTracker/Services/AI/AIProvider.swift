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
    /// Resolved from the short id the model returns (e.g. "T2"). Nil when the model
    /// declined to pick one, named something unknown, or was ambiguous.
    let todo: Todo?
    let rationale: String
    let raw: String
}

/// Providers implement one thing: turn a (system, user) pair into text.
///
/// Everything prompt-specific lives in the default implementations below, so adding a
/// new kind of question — as `decideBoundary` does — costs nothing per provider and
/// leaves every existing call site untouched.
protocol AIProvider {
    var id: UUID { get }
    var displayName: String { get }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

extension AIProvider {
    /// A ceiling, not a target. The answer is a small JSON object, but on models that
    /// think, the thinking counts against `max_tokens`; 512 regularly left nothing for
    /// the answer itself.
    static var answerTokenCeiling: Int { 4096 }

    /// Classify a window of activity. The original question, unchanged.
    func draft(_ context: SuggestionContext) async throws -> EntryDraft {
        let (system, user) = PromptBuilder.build(context: context)
        let text = try await complete(system: system, user: user, maxTokens: Self.answerTokenCeiling)
        return try DraftParser.parse(text, context: context, providerLabel: displayName)
    }

    /// Adjudicate a boundary the local signals already proposed: did the task change,
    /// and if so exactly when?
    func decideBoundary(_ context: BoundaryContext) async throws -> BoundaryVerdict {
        let (system, user) = BoundaryPromptBuilder.build(context: context)
        let text = try await complete(system: system, user: user, maxTokens: Self.answerTokenCeiling)
        return try BoundaryParser.parse(text, context: context, providerLabel: displayName)
    }
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
    /// The model declined (a safety classifier), with its category if given.
    case refused(String?)
    /// The answer hit `max_tokens` before it was complete.
    case truncated

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured: return "No AI provider is configured. Open Settings → AI."
        case .badStatus(let code, let body): return "AI provider returned HTTP \(code): \(body)"
        case .emptyResponse: return "AI provider returned an empty response."
        case .parseFailed(let s): return "Could not parse AI response: \(s)"
        case .refused(let category): return "The model declined to answer\(category.map { " (\($0))" } ?? "")."
        case .truncated: return "The AI response was cut off before it was complete."
        }
    }
}
