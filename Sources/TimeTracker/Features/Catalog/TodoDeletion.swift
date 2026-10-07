import SwiftUI
import SwiftData

/// Deleting a todo, from wherever it is offered, with the same confirmation.
enum TodoDeletion {
    /// Every todo below this one.
    static func descendants(of todo: Todo) -> [Todo] {
        todo.subtasks.flatMap { [$0] + descendants(of: $0) }
    }

    /// "Delete “Read SoW” and its 2 subtasks? 3 time entries keep their time…"
    static func message(for todo: Todo) -> String {
        let subtasks = descendants(of: todo)
        let entries = ([todo] + subtasks).reduce(0) { $0 + $1.linkedEntries.count }
        var parts: [String] = []
        if !subtasks.isEmpty {
            parts.append("Its \(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s") will be deleted too.")
        }
        if entries > 0 {
            parts.append("\(entries) time entr\(entries == 1 ? "y keeps its" : "ies keep their") time but lose\(entries == 1 ? "s" : "") the link.")
        }
        parts.append("This can't be undone.")
        return parts.joined(separator: " ")
    }

    @MainActor
    static func delete(_ todo: Todo, context: ModelContext) {
        // Subtasks cascade with their parent; entries keep their time (nullify).
        context.delete(todo)
        try? context.save()
    }
}

extension View {
    /// Asks before deleting `todo`, then deletes it.
    /// `onDeleted` receives the id of the todo that was deleted.
    func confirmingTodoDelete(_ todo: Binding<Todo?>, context: ModelContext,
                              onDeleted: @escaping (UUID) -> Void = { _ in }) -> some View {
        confirmationDialog(
            "Delete “\(todo.wrappedValue?.title ?? "")”?",
            isPresented: Binding(get: { todo.wrappedValue != nil }, set: { if !$0 { todo.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: todo.wrappedValue
        ) { target in
            Button("Delete", role: .destructive) {
                let id = target.id
                TodoDeletion.delete(target, context: context)
                todo.wrappedValue = nil
                onDeleted(id)
            }
            Button("Cancel", role: .cancel) { todo.wrappedValue = nil }
        } message: { target in
            Text(TodoDeletion.message(for: target))
        }
    }
}
