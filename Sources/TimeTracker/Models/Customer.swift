import Foundation
import SwiftData

@Model
final class Customer {
    @Attribute(.unique) var id: UUID
    var name: String
    var defaultBillable: Bool
    var createdAt: Date

    /// Deleting a customer keeps its projects (they become customer-less) rather than
    /// silently deleting them and the attribution of every past entry with them.
    @Relationship(deleteRule: .nullify, inverse: \Project.customer)
    var projects: [Project] = []

    // Inverses with `.nullify`, so deleting this leaves past entries in place with
    // the link cleared, instead of dangling references to a deleted model.
    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.customer)
    var entries: [TimeEntry] = []

    @Relationship(deleteRule: .cascade, inverse: \ClassificationRule.targetCustomer)
    var rules: [ClassificationRule] = []

    init(
        id: UUID = UUID(),
        name: String,
        defaultBillable: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.defaultBillable = defaultBillable
        self.createdAt = createdAt
    }
}
