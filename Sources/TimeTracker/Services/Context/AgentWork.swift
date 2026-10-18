import Foundation
import SwiftData

/// What agents need, besides context, to work on the user's todos on their own: each
/// todo's brief, and the user's rules on what they may do without asking.
@MainActor
enum TaskBrief {

    static let sections = ["## Goal", "## Deliverable", "## Done when", "## Constraints", "## Plan"]
    static let limit = 4000

    static var template: String {
        """
        ## Goal
        Why this todo exists, in one or two lines.
        ## Deliverable
        What exists when it is done: an email, a Confluence page, a dashboard, code…
        ## Done when
        - checkable criteria
        ## Constraints
        - deadlines, sensitive data, who must approve
        ## Plan
        - [ ] step (auto)
        - [ ] step that needs the user's OK (ask)
        """
    }

    /// What is wrong with a brief, or nil when it can be saved.
    static func problem(_ markdown: String) -> String? {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "The brief is empty." }
        if text.count > limit { return "The brief has \(text.count) characters; the limit is \(limit). Keep it to what an agent needs to act." }
        let lines = Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = sections.filter { !lines.contains($0) }
        if !missing.isEmpty {
            return "Missing sections: \(missing.joined(separator: ", ")). Use exactly these headings: \(sections.joined(separator: ", "))."
        }
        if steps(in: text).isEmpty {
            return "The Plan needs at least one step written as \"- [ ] step (auto)\" or \"- [ ] step (ask)\"."
        }
        return nil
    }

    struct Step: Equatable {
        var text: String
        var done: Bool
        /// Needs the user's OK before it is done.
        var needsApproval: Bool
    }

    /// The checklist under "## Plan".
    static func steps(in brief: String) -> [Step] {
        var inPlan = false
        var steps: [Step] = []
        for raw in brief.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { inPlan = line == "## Plan"; continue }
            guard inPlan else { continue }
            let done: Bool
            if line.hasPrefix("- [ ] ") { done = false } else if line.lowercased().hasPrefix("- [x] ") { done = true } else { continue }
            let text = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            steps.append(Step(text: text, done: done, needsApproval: text.lowercased().hasSuffix("(ask)")))
        }
        return steps
    }

    static func save(_ todo: Todo, markdown: String, context: ModelContext, now: Date = Date()) throws {
        guard !todo.isExcludedFromContext else {
            throw DossierService.Rejection(message: "This todo is kept out of AI context.")
        }
        if let problem = problem(markdown) { throw DossierService.Rejection(message: problem) }
        todo.brief = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        todo.briefUpdatedAt = now
        try? context.save()
    }
}

/// The user's rules for agents: what they do on their own, what they ask first, and
/// what they never do. Shown to every agent through Hansel, editable in Settings.
enum AutonomyPolicy {
    static let defaultsKey = "agents.autonomyPolicy"

    static var current: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultText : stored
    }

    static let defaultText = """
    ## Do without asking
    - Read anything in Hansel, Slack, email, the calendar, Teams, Zoom, Confluence and GitHub.
    - Write drafts (emails, Slack messages, Confluence pages) and leave them unsent and unpublished.
    - Create and edit todos, briefs, dossiers and time entries in Hansel.
    - Run code, scripts and API calls in a scratch folder or a test environment.
    - Write in the user's personal Confluence space.
    - Tick off brief steps marked (auto) once they are done.

    ## Ask first
    - Sending anything to anyone, or posting in a shared channel or space.
    - Any step of a brief marked (ask).
    - Sharing one customer's data with another customer or anyone outside the company.
    - Changing production systems or shared data.
    - Accepting meetings, committing to dates or spending money on the user's behalf.

    ## Never
    - Delete anything.
    - Put credentials, tokens or personal matters in any message, page, brief or dossier.
    - Touch anything about customers kept out of AI context.
    """
}
