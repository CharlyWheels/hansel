import Foundation
import SwiftData

@Model
final class Todo {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String?
    var isCompleted: Bool
    var createdAt: Date
    var completedAt: Date?
    var dueAt: Date?
    var sortOrder: Int

    var parent: Todo?

    @Relationship(deleteRule: .cascade, inverse: \Todo.parent)
    var subtasks: [Todo] = []

    var relatedProject: Project?

    init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        dueAt: Date? = nil,
        sortOrder: Int = 0,
        parent: Todo? = nil,
        relatedProject: Project? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.dueAt = dueAt
        self.sortOrder = sortOrder
        self.parent = parent
        self.relatedProject = relatedProject
    }
}

enum TodoDueStatus {
    case none
    case overdue
    case dueToday
    case dueSoon  // within 3 days
    case future
}

extension Todo {
    var dueStatus: TodoDueStatus {
        guard let due = dueAt else { return .none }
        let now = Date()
        let cal = Calendar.current
        if due < cal.startOfDay(for: now) { return .overdue }
        if cal.isDate(due, inSameDayAs: now) { return .dueToday }
        if let in3 = cal.date(byAdding: .day, value: 3, to: now), due <= in3 { return .dueSoon }
        return .future
    }
}

extension Todo {
    /// Children sorted by sortOrder then createdAt — used by the prompt builder
    /// and tree views so order is stable everywhere.
    var orderedSubtasks: [Todo] {
        subtasks.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }
    }

    /// Walks the parent chain to build a "Root › Child › This" path,
    /// used in pickers so subtasks are unambiguous.
    var breadcrumbPath: String {
        var parts: [String] = [title]
        var node = parent
        while let p = node {
            parts.insert(p.title, at: 0)
            node = p.parent
        }
        return parts.joined(separator: " › ")
    }

    /// True if `candidate` is `self` or one of its descendants — used to prevent
    /// cycles when offering a parent picker.
    func contains(_ candidate: Todo) -> Bool {
        if candidate.id == id { return true }
        return subtasks.contains { $0.contains(candidate) }
    }
}
