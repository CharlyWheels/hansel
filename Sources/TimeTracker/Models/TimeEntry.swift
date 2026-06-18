import Foundation
import SwiftData

enum EntrySource: String, Codable, CaseIterable, Hashable {
    case manual
    case calendar
    case aiAutoStart
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
    var sourceRaw: String
    var billableCached: Bool
    var notes: String?
    var linkedTodo: Todo?

    init(
        id: UUID = UUID(),
        title: String = "",
        startAt: Date = Date(),
        endAt: Date? = nil,
        role: Role? = nil,
        project: Project? = nil,
        customer: Customer? = nil,
        isConfirmed: Bool = false,
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
        self.sourceRaw = source.rawValue
        self.billableCached = billableCached
        self.notes = notes
        self.linkedTodo = linkedTodo
    }

    var source: EntrySource {
        get { EntrySource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var duration: TimeInterval? {
        guard let endAt else { return nil }
        return endAt.timeIntervalSince(startAt)
    }

    func refreshBillableCache() {
        billableCached = BillableResolver.resolve(role: role, project: project, customer: customer)
    }
}
