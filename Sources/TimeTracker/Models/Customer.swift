import Foundation
import SwiftData

@Model
final class Customer {
    @Attribute(.unique) var id: UUID
    var name: String
    var defaultBillable: Bool
    var createdAt: Date
    /// Comma-separated names this customer is known by elsewhere: email domains
    /// ("acme.com"), abbreviations ("ITX"), Slack channels ("#acme-rollout") and
    /// contacts ("jane@acme.com"). `CustomerMatcher.aliases(of:)` reads the kind from
    /// each one's shape. Stored in the column that held only email domains before.
    @Attribute(originalName: "emailDomains") var aliases: String = ""
    /// Keeps this customer's todos, meetings and messages out of everything gathered
    /// as context for AI assistants (e.g. a "Personal" customer).
    var excludedFromContext: Bool = false

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

    /// Deleting a customer leaves its todos without one, to be assigned again.
    @Relationship(deleteRule: .nullify, inverse: \Todo.customer)
    var todos: [Todo] = []

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
