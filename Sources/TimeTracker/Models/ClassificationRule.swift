import Foundation
import SwiftData

/// User-defined rule that biases AI classification toward a Role, Project, or Customer.
/// Exactly one of `targetRole` / `targetProject` / `targetCustomer` is set — each rule
/// points at the entity it classifies to. Conditions are AND-combined; a rule matches
/// when every non-nil condition is satisfied. Empty rules (no conditions) never match.
@Model
final class ClassificationRule {
    @Attribute(.unique) var id: UUID
    var name: String
    var priority: Int
    var isEnabled: Bool
    var createdAt: Date

    // Target (exactly one of the three should be non-nil, enforced by the editor UI).
    var targetRole: Role?
    var targetProject: Project?
    var targetCustomer: Customer?

    // Conditions (optional; any non-nil one must match).
    var appBundleID: String?
    var appNameContains: String?
    var urlContains: String?
    var windowTitleContains: String?
    var calendarTitleContains: String?

    init(
        id: UUID = UUID(),
        name: String,
        priority: Int = 0,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        targetRole: Role? = nil,
        targetProject: Project? = nil,
        targetCustomer: Customer? = nil,
        appBundleID: String? = nil,
        appNameContains: String? = nil,
        urlContains: String? = nil,
        windowTitleContains: String? = nil,
        calendarTitleContains: String? = nil
    ) {
        self.id = id
        self.name = name
        self.priority = priority
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.targetRole = targetRole
        self.targetProject = targetProject
        self.targetCustomer = targetCustomer
        self.appBundleID = appBundleID
        self.appNameContains = appNameContains
        self.urlContains = urlContains
        self.windowTitleContains = windowTitleContains
        self.calendarTitleContains = calendarTitleContains
    }

    /// A short, user-readable description of this rule's conditions,
    /// e.g. "app com.microsoft.powerbi.desktop".
    var conditionsSummary: String {
        var parts: [String] = []
        if let b = appBundleID, !b.isEmpty { parts.append("app \(b)") }
        if let a = appNameContains, !a.isEmpty { parts.append("app name ~ \"\(a)\"") }
        if let u = urlContains, !u.isEmpty { parts.append("url ~ \"\(u)\"") }
        if let w = windowTitleContains, !w.isEmpty { parts.append("title ~ \"\(w)\"") }
        if let c = calendarTitleContains, !c.isEmpty { parts.append("event ~ \"\(c)\"") }
        return parts.isEmpty ? "(no conditions)" : parts.joined(separator: " · ")
    }

    var hasAnyCondition: Bool {
        [appBundleID, appNameContains, urlContains, windowTitleContains, calendarTitleContains]
            .contains { !($0?.isEmpty ?? true) }
    }
}
