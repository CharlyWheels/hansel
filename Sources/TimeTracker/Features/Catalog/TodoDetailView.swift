import SwiftUI
import SwiftData

struct TodoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var todo: Todo

    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]
    @Query(sort: [SortDescriptor(\Project.name)]) private var projects: [Project]

    @State private var newSubtaskTitle: String = ""

    private var parentCandidates: [Todo] {
        // `todo.contains` already returns true for self and descendants, so excluding
        // them in one step also prevents picking a parent that would create a cycle.
        allTodos.filter { !todo.contains($0) }
    }

    var body: some View {
        Form {
            if let parent = todo.parent {
                Section {
                    // Subtasks are todos like any other; this is the way back up.
                    NavigationLink(value: parent) {
                        Label {
                            Text("Part of ") + Text(parent.breadcrumbPath).bold()
                        } icon: {
                            Image(systemName: "arrow.turn.left.up")
                        }
                    }
                }
            }
            Section(todo.parent == nil ? "Todo" : "Subtask") {
                TextField("Title", text: $todo.title)
                TextField(
                    "Notes",
                    text: Binding(
                        get: { todo.notes ?? "" },
                        set: { todo.notes = $0.isEmpty ? nil : $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(2...6)
                Toggle("Completed", isOn: Binding(
                    get: { todo.isCompleted },
                    set: { newValue in
                        todo.isCompleted = newValue
                        todo.completedAt = newValue ? Date() : nil
                    }
                ))
            }

            Section("Hierarchy") {
                Picker("Parent", selection: parentBinding) {
                    Text("None (root)").tag(Optional<Todo>.none)
                    ForEach(parentCandidates) { candidate in
                        Text(candidate.breadcrumbPath).tag(Optional(candidate))
                    }
                }
                Picker("Related project", selection: $todo.relatedProject) {
                    Text(inheritedLabel).tag(Optional<Project>.none)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project))
                    }
                }
            }

            Section("Deadline") {
                Toggle("Has deadline", isOn: hasDeadlineBinding)
                if todo.dueAt != nil {
                    DatePicker(
                        "Due",
                        selection: Binding(
                            get: { todo.dueAt ?? Date() },
                            set: { todo.dueAt = $0 }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }

            Section {
                ForEach(todo.orderedSubtasks) { sub in
                    // Opens the subtask with this same page: notes, deadline, project and
                    // its own subtasks, like any todo.
                    NavigationLink(value: sub) {
                        HStack(spacing: 8) {
                            Button {
                                sub.isCompleted.toggle()
                                sub.completedAt = sub.isCompleted ? Date() : nil
                                try? modelContext.save()
                            } label: {
                                Image(systemName: sub.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(sub.isCompleted ? .green : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(sub.isCompleted ? "Mark not done" : "Mark done")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.title.isEmpty ? "(untitled)" : sub.title)
                                    .strikethrough(sub.isCompleted)
                                    .foregroundStyle(sub.isCompleted ? .secondary : .primary)
                                if let notes = sub.notes, !notes.isEmpty {
                                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if let project = sub.relatedProject {
                                Chip(text: project.name, systemImage: "folder", color: project.displayColor)
                            }
                            if !sub.subtasks.isEmpty {
                                let done = sub.subtasks.filter(\.isCompleted).count
                                Chip(text: "\(done)/\(sub.subtasks.count)", systemImage: "list.bullet")
                            }
                            DueDateBadge(todo: sub)
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            modelContext.delete(sub)
                            try? modelContext.save()
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                    TextField("Add a subtask and press Return", text: $newSubtaskTitle)
                        .textFieldStyle(.plain)
                        .onSubmit(addSubtask)
                    if !newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add", action: addSubtask).controlSize(.small)
                    }
                }
            } header: {
                Text("Subtasks")
            } footer: {
                Text("Open a subtask to give it notes, a deadline, a project or its own subtasks. Right-click to delete.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(todo.title.isEmpty ? "Todo" : todo.title)
        .onChange(of: todo.title) { _, _ in try? modelContext.save() }
        .onChange(of: todo.notes) { _, _ in try? modelContext.save() }
        .onChange(of: todo.isCompleted) { _, _ in try? modelContext.save() }
        .onChange(of: todo.relatedProject) { _, _ in try? modelContext.save() }
        .onChange(of: todo.dueAt) { _, _ in try? modelContext.save() }
    }

    /// What "no project" means here: none, or the one inherited from a parent.
    private var inheritedLabel: String {
        if todo.relatedProject == nil, let inherited = todo.parent?.inheritedProject {
            return "Same as parent (\(inherited.name))"
        }
        return todo.parent == nil ? "None" : "Same as parent"
    }

    private var parentBinding: Binding<Todo?> {
        Binding(
            get: { todo.parent },
            set: { newParent in
                todo.parent = newParent
                try? modelContext.save()
            }
        )
    }

    private var hasDeadlineBinding: Binding<Bool> {
        Binding(
            get: { todo.dueAt != nil },
            set: { hasDeadline in
                if hasDeadline {
                    // Default to end of today so the user gets a sensible starting value.
                    let cal = Calendar.current
                    let endOfToday = cal.date(
                        bySettingHour: 18,
                        minute: 0,
                        second: 0,
                        of: Date()
                    ) ?? Date().addingTimeInterval(8 * 3600)
                    todo.dueAt = endOfToday
                } else {
                    todo.dueAt = nil
                }
                try? modelContext.save()
            }
        )
    }

    private func addSubtask() {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (todo.subtasks.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(
            Todo(title: trimmed, sortOrder: nextOrder, parent: todo)
        )
        try? modelContext.save()
        newSubtaskTitle = ""
    }
}
