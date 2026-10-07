import SwiftUI
import SwiftData

extension Todo {
    /// First project found by walking the parent chain (including self).
    /// Subtasks inherit the project of their nearest ancestor when they don't
    /// have their own `relatedProject` set.
    var inheritedProject: Project? {
        var node: Todo? = self
        while let n = node {
            if let p = n.relatedProject { return p }
            node = n.parent
        }
        return nil
    }

    /// Color used for the todo's title text when it (or an ancestor) is tied to
    /// a project. Returns nil when no project is in the chain — callers fall
    /// back to the default text color.
    var inheritedDisplayColor: Color? {
        inheritedProject?.displayColor
    }
}

struct TodosView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]

    @State private var newTitle: String = ""
    @State private var showCompleted: Bool = false
    @State private var pendingDelete: IndexSet?

    private var rootTodos: [Todo] {
        allTodos.filter { $0.parent == nil && (showCompleted || !$0.isCompleted) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                addRow.padding()
                Divider()
                List {
                    // Inside the list, so it scrolls with it. Above the list it had no
                    // height limit: with a handful of proposals it outgrew the window
                    // and the whole window drew blank.
                    ProposalInboxSection()
                        .listRowSeparator(.hidden)
                    ForEach(rootTodos) { todo in
                        TodoRowRecursive(
                            todo: todo,
                            depth: 0,
                            showCompleted: showCompleted,
                            onToggle: toggleCompleted
                        )
                    }
                    .onDelete { pendingDelete = $0 }
                }
                .listStyle(.inset)
                .confirmingDelete($pendingDelete, noun: "todo and its subtasks",
                                  affectedEntries: { $0.reduce(0) { sum, i in sum + rootTodos[i].linkedEntries.count } },
                                  perform: deleteRoots)
            }
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: $showCompleted) {
                        Label("Show completed", systemImage: "checkmark.circle")
                    }
                    .toggleStyle(.button)
                }
            }
            .navigationDestination(for: Todo.self) { todo in
                TodoDetailView(todo: todo)
            }
        }
    }

    private var addRow: some View {
        HStack {
            TextField("Todo title", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addRoot)
            Button("Add", action: addRoot)
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addRoot() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (rootTodos.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(Todo(title: trimmed, sortOrder: nextOrder))
        try? modelContext.save()
        newTitle = ""
    }

    private func toggleCompleted(_ todo: Todo) {
        todo.isCompleted.toggle()
        todo.completedAt = todo.isCompleted ? Date() : nil
        try? modelContext.save()
    }

    private func deleteRoots(offsets: IndexSet) {
        for i in offsets { modelContext.delete(rootTodos[i]) }
        try? modelContext.save()
    }

    fileprivate static func titleColor(for todo: Todo) -> Color {
        if todo.isCompleted { return .secondary }
        return todo.inheritedDisplayColor ?? .primary
    }

    fileprivate static func rowSummary(
        _ todo: Todo,
        depth: Int,
        onToggle: @escaping (Todo) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                onToggle(todo)
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title.isEmpty ? "(untitled)" : todo.title)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(titleColor(for: todo))
                HStack(spacing: 6) {
                    if !todo.subtasks.isEmpty {
                        let done = todo.subtasks.filter(\.isCompleted).count
                        Text("\(done)/\(todo.subtasks.count) subtasks")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let project = todo.inheritedProject {
                        Text(project.name)
                            .font(.caption2)
                            .foregroundStyle(project.displayColor)
                    }
                }
            }
            Spacer()
            DueDateBadge(todo: todo)
        }
        .contentShape(Rectangle())
    }
}

struct DueDateBadge: View {
    let todo: Todo

    var body: some View {
        if let due = todo.dueAt, !todo.isCompleted {
            let status = todo.dueStatus
            Label(format(due, status: status), systemImage: "calendar")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color(for: status).opacity(0.15), in: Capsule())
                .foregroundStyle(color(for: status))
        }
    }

    private func color(for status: TodoDueStatus) -> Color {
        switch status {
        case .none, .future: return .secondary
        case .overdue: return .red
        case .dueToday: return .orange
        case .dueSoon: return .yellow
        }
    }

    private func format(_ date: Date, status: TodoDueStatus) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
            return "today \(f.string(from: date))"
        }
        if cal.isDateInTomorrow(date) {
            f.dateFormat = "HH:mm"
            return "tomorrow \(f.string(from: date))"
        }
        if status == .overdue {
            f.dateFormat = "MMM d"
            return "overdue \(f.string(from: date))"
        }
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

/// Recursive tree node — split into its own struct so `body` doesn't form
/// a self-referential opaque return type.
private struct TodoRowRecursive: View {
    let todo: Todo
    let depth: Int
    let showCompleted: Bool
    let onToggle: (Todo) -> Void

    var body: some View {
        let visibleChildren = todo.orderedSubtasks.filter { showCompleted || !$0.isCompleted }
        if visibleChildren.isEmpty {
            NavigationLink(value: todo) {
                TodosView.rowSummary(todo, depth: depth, onToggle: onToggle)
            }
        } else {
            DisclosureGroup {
                ForEach(visibleChildren) { child in
                    TodoRowRecursive(
                        todo: child,
                        depth: depth + 1,
                        showCompleted: showCompleted,
                        onToggle: onToggle
                    )
                }
            } label: {
                NavigationLink(value: todo) {
                    TodosView.rowSummary(todo, depth: depth, onToggle: onToggle)
                }
            }
        }
    }
}
