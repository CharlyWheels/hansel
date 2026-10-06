import Foundation
import SwiftData

/// What the user's past decisions on proposals say about the next ones.
///
/// Three lessons, all read from resolved proposals rather than stored separately, so
/// deleting the history is the whole reset:
/// - the project the user moved tasks to, per recurring meeting;
/// - recurring meetings whose proposals the user always declines;
/// - examples for the model: what was declined, and how titles were rewritten.
enum ProposalLearning {

    /// One resolved proposal, reduced to what the lessons need.
    struct Decision: Equatable {
        var meetingTitle: String
        var accepted: Bool
        var resolvedAt: Date
        var suggestedTitle: String
        var finalTitle: String
        var suggestedProjectID: UUID?
        /// The project the todo has now, which includes changes made after accepting.
        var finalProjectID: UUID?
    }

    static let minimumDeclinesForHint = 3
    static let historyDays: Double = 180

    /// Meeting titles with dates, numbers and punctuation removed, so "Weekly sync 12/10"
    /// and "Weekly sync #43" are the same meeting.
    static func recurringKey(_ title: String) -> String {
        title.lowercased()
            .unicodeScalars
            .map { CharacterSet.letters.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// The project of the most recent accepted task from this recurring meeting whose
    /// project the user chose differently from what was suggested.
    static func learnedProjectID(forMeetingTitle title: String, decisions: [Decision]) -> UUID? {
        let key = recurringKey(title)
        guard !key.isEmpty else { return nil }
        return decisions
            .filter { $0.accepted && recurringKey($0.meetingTitle) == key }
            .filter { $0.finalProjectID != nil && $0.finalProjectID != $0.suggestedProjectID }
            .max { $0.resolvedAt < $1.resolvedAt }?
            .finalProjectID
    }

    /// A warning when every proposal from earlier instances of this meeting was declined.
    static func meetingHint(forMeetingTitle title: String, decisions: [Decision]) -> String? {
        let key = recurringKey(title)
        guard !key.isEmpty else { return nil }
        let same = decisions.filter { recurringKey($0.meetingTitle) == key }
        let declined = same.filter { !$0.accepted }.count
        guard declined >= minimumDeclinesForHint, !same.contains(where: \.accepted) else { return nil }
        return "You declined all \(declined) earlier proposals from this meeting."
    }

    /// Recent examples for the prompt, newest first and without repeats.
    static func examples(
        decisions: [Decision],
        maxDeclined: Int = 12,
        maxCorrections: Int = 8
    ) -> (declined: [String], corrections: [(from: String, to: String)]) {
        let recent = decisions.sorted { $0.resolvedAt > $1.resolvedAt }
        var seen = Set<String>()
        let declined = recent.filter { !$0.accepted }.map(\.suggestedTitle).filter {
            seen.insert($0.lowercased()).inserted
        }
        let corrections = recent
            .filter { $0.accepted && normalized($0.finalTitle) != normalized($0.suggestedTitle) }
            .map { (from: $0.suggestedTitle, to: $0.finalTitle) }
        return (Array(declined.prefix(maxDeclined)), Array(corrections.prefix(maxCorrections)))
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - From the store

    @MainActor
    static func decisions(context: ModelContext, now: Date = Date()) -> [Decision] {
        let since = now.addingTimeInterval(-historyDays * 86_400)
        let pending = TodoProposal.Status.pending.rawValue
        let resolved = (try? context.fetch(FetchDescriptor<TodoProposal>(
            predicate: #Predicate { $0.statusRaw != pending && $0.createdAt >= since }
        ))) ?? []
        let acceptedIDs = Set(resolved.compactMap(\.acceptedTodoID))
        let todos = acceptedIDs.isEmpty ? [] : ((try? context.fetch(FetchDescriptor<Todo>())) ?? [])
            .filter { acceptedIDs.contains($0.id) }
        let todoProject = Dictionary(todos.map { ($0.id, $0.relatedProject?.id) }, uniquingKeysWith: { a, _ in a })
        return resolved.map { p in
            let accepted = p.status == .accepted
            // A deleted todo leaves the project chosen when accepting.
            let current = p.acceptedTodoID.flatMap { todoProject[$0] } ?? p.projectID
            return Decision(
                meetingTitle: p.meetingTitle,
                accepted: accepted,
                resolvedAt: p.resolvedAt ?? p.createdAt,
                suggestedTitle: p.suggestedTitle,
                finalTitle: p.title,
                suggestedProjectID: p.suggestedProjectID,
                finalProjectID: accepted ? current : nil
            )
        }
    }

    /// Forgets everything learned: decided proposals go, undecided ones stay.
    @MainActor
    static func reset(context: ModelContext) {
        let pending = TodoProposal.Status.pending.rawValue
        let resolved = (try? context.fetch(FetchDescriptor<TodoProposal>(
            predicate: #Predicate { $0.statusRaw != pending }
        ))) ?? []
        resolved.forEach { context.delete($0) }
        try? context.save()
    }
}
