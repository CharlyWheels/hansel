import Foundation
import Observation

/// The last prompt of each kind and what came back, for Settings → Debug.
///
/// Memory only: prompts carry window titles and URLs, so they are never written to
/// disk. Without this there was no way to see what the model was actually given.
@Observable
@MainActor
final class PromptInspector {
    static let shared = PromptInspector()

    enum Kind: String, CaseIterable, Identifiable {
        case draft = "Activity draft"
        case boundary = "Task switch"
        var id: String { rawValue }
    }

    struct Record: Equatable {
        let kind: Kind
        let at: Date
        let provider: String
        let system: String
        let user: String
        var response: String?
        var error: String?
    }

    private(set) var records: [Kind: Record] = [:]

    func record(_ record: Record) {
        records[record.kind] = record
    }
}

extension AIProvider {
    /// Runs one model call and records the exchange for the Debug pane.
    func inspectedComplete(kind: PromptInspector.Kind, system: String, user: String) async throws -> String {
        let at = Date()
        let provider = displayName
        do {
            let text = try await complete(system: system, user: user, maxTokens: Self.answerTokenCeiling)
            await MainActor.run {
                PromptInspector.shared.record(.init(kind: kind, at: at, provider: provider,
                                                    system: system, user: user, response: text))
            }
            return text
        } catch {
            let message = error.localizedDescription
            await MainActor.run {
                PromptInspector.shared.record(.init(kind: kind, at: at, provider: provider,
                                                    system: system, user: user, error: message))
            }
            throw error
        }
    }
}
