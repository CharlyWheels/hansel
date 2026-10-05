import Foundation
import SwiftData

@Model
final class Role {
    @Attribute(.unique) var id: UUID
    var name: String
    var defaultBillable: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ClassificationRule.targetRole)
    var rules: [ClassificationRule] = []

    // Inverses with `.nullify`, so deleting this leaves past entries in place with
    // the link cleared, instead of dangling references to a deleted model.
    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.role)
    var entries: [TimeEntry] = []

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
