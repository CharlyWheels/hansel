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
