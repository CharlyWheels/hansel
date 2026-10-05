import Foundation
import SwiftData

enum EntrySource: String, Codable, CaseIterable, Hashable {
    case manual
    case calendar
    case aiAutoStart
    /// Opened by an accepted boundary proposal, splitting a previous entry.
    case aiSwitch
    /// Rewritten in place after the user corrected a proposal.
    case userCorrected
}

@Model
final class TimeEntry {
    @Attribute(.unique) var id: UUID
    var title: String
    var startAt: Date
    var endAt: Date?
    var role: Role?
    var project: Project?
    var customer: Customer?
    var isConfirmed: Bool
    /// True only when a human created this entry or explicitly approved it.
    ///
    /// Distinct from `isConfirmed`, which merely means "closed". `stop()` used to set
    /// `isConfirmed = true` on *every* entry including ones the AI and the calendar
    /// created unattended, and both `SuggestionEngine.fetchRecentEntries` and
    /// `CalendarService.classify` then fed those rows back to the model as ground
    /// truth — the app taught the model its own mistakes and called them examples.
    /// Retrieval for classification must filter on this flag, never on `isConfirmed`.
    ///
    /// Default lives on the declaration (not in `init`) so SwiftData can migrate.
    var isHumanConfirmed: Bool = false
    var sourceRaw: String
    var billableCached: Bool
    var notes: String?
    var linkedTodo: Todo?

    // MARK: - Split chain (undo)
    //
    // Defaults live on the declarations so SwiftData lightweight migration applies
    // them; a default supplied only in `init` does not migrate.

    /// The entry this one was split off from, if any.
    var previousEntryID: UUID? = nil
    /// The entry that superseded this one when it was split.
    var supersededByID: UUID? = nil

    init(
        id: UUID = UUID(),
        title: String = "",
        startAt: Date = Date(),
        endAt: Date? = nil,
        role: Role? = nil,
        project: Project? = nil,
        customer: Customer? = nil,
        isConfirmed: Bool = false,
        isHumanConfirmed: Bool = false,
        source: EntrySource = .manual,
        billableCached: Bool = false,
        notes: String? = nil,
        linkedTodo: Todo? = nil
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.role = role
        self.project = project
        self.customer = customer
        self.isConfirmed = isConfirmed
        self.isHumanConfirmed = isHumanConfirmed
        self.sourceRaw = source.rawValue
        self.billableCached = billableCached
        self.notes = notes
        self.linkedTodo = linkedTodo
    }

    var source: EntrySource {
        get { EntrySource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// A closed entry no human has vouched for. Drives the review UI.
    var needsReview: Bool { endAt != nil && !isHumanConfirmed }

    var duration: TimeInterval? {
        guard let endAt else { return nil }
        return endAt.timeIntervalSince(startAt)
    }

    func refreshBillableCache() {
        billableCached = BillableResolver.resolve(role: role, project: project, customer: customer)
    }
}
