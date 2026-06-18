import Foundation
import SwiftData

@Model
final class Customer {
    @Attribute(.unique) var id: UUID
    var name: String
    var defaultBillable: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Project.customer)
    var projects: [Project] = []

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
