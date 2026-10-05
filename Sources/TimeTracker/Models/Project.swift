import Foundation
import SwiftData
import SwiftUI

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var defaultBillable: Bool
    var createdAt: Date
    var customer: Customer?
    /// User-chosen color as 6-char hex (RRGGBB). When nil, falls back to a deterministic
    /// hue hashed from the project name.
    var colorHex: String?

    @Relationship(deleteRule: .cascade, inverse: \ClassificationRule.targetProject)
    var rules: [ClassificationRule] = []

    // Inverses with `.nullify`, so deleting this leaves past entries in place with
    // the link cleared, instead of dangling references to a deleted model.
    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.project)
    var entries: [TimeEntry] = []

    @Relationship(deleteRule: .nullify, inverse: \Todo.relatedProject)
    var todos: [Todo] = []

    init(
        id: UUID = UUID(),
        name: String,
        customer: Customer? = nil,
        defaultBillable: Bool = true,
        createdAt: Date = Date(),
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.customer = customer
        self.defaultBillable = defaultBillable
        self.createdAt = createdAt
        self.colorHex = colorHex
    }
}

extension Project {
    /// The color shown wherever this project's entries appear. Uses `colorHex` if set,
    /// otherwise a deterministic hash of the project name so identical projects always
    /// look the same.
    var displayColor: Color {
        if let color = Color(hex: colorHex) { return color }
        let hue = Double(abs(name.hashValue) % 360) / 360
        return Color(hue: hue, saturation: 0.72, brightness: 0.78)
    }
}
