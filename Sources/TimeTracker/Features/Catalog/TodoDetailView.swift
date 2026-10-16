import SwiftUI
import SwiftData

struct TodoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var todo: Todo

    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]
    @Query(sort: [SortDescriptor(\Project.name)]) private var projects: [Project]
    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]

    @State private var newSubtaskTitle: String = ""
    @State private var deleting: Todo?
    @Environment(\.dismiss) private var dismiss
    @Environment(MainWindowRouter.self) private var router

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
                if todo.parent == nil {
                    Picker("Customer", selection: customerBinding) {
                        Text("None").tag(Optional<Customer>.none)
                        ForEach(customers) { customer in
                            Text(customer.name).tag(Optional(customer))
                        }
                    }
                    // A project's customer is the todo's customer.
                    .disabled(todo.relatedProject?.customer != nil)
                } else {
                    LabeledContent("Customer") {
                        Text(todo.effectiveCustomer.map { "\($0.name) (from parent)" } ?? "None (set it on the parent)")
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Related project", selection: projectBinding) {
                    Text(inheritedLabel).tag(Optional<Project>.none)
                    ForEach(projectChoices) { project in
                        Text(project.customer.map { "\(project.name) — \($0.name)" } ?? project.name)
                            .tag(Optional(project))
                    }
                }
            }

            if todo.isExcludedFromContext {
                Section("Dossier") {
                    Text("This todo's customer is kept out of AI context, so it has no dossier.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                DossierSection(
                    dossier: $todo.brief, updatedAt: todo.briefUpdatedAt, title: "Brief",
                    emptyText: "No brief yet. Ask an agent to work on this todo and it drafts one, or write it yourself: goal, deliverable, when it is done, constraints and plan.",
                    template: TaskBrief.template, caption: briefProgress(todo)
                ) {
                    todo.briefUpdatedAt = Date()
                    try? modelContext.save()
                }
                DossierSection(dossier: $todo.dossier, updatedAt: todo.dossierUpdatedAt) {
                    todo.dossierUpdatedAt = Date()
                    try? modelContext.save()
                }
                Section {
                    HStack {
                        Button("Open in Context") { router.openContext(.todo(todo.id)) }
                            .buttonStyle(.link)
                        Spacer()
                        GatherButton(todo: todo)
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
                        Button("Delete…", role: .destructive) { deleting = sub }
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
                Text("Open a subtask to give it notes, a deadline, a project or its own subtasks. Right-click a subtask to delete it.")
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { deleting = todo } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this todo")
            }
        }
        // Leave the page only when its own todo was deleted, not one of its subtasks.
        .confirmingTodoDelete($deleting, context: modelContext) { [todoID = todo.id] deleted in
            if deleted == todoID { dismiss() }
        }
        .navigationTitle(todo.title.isEmpty ? "Todo" : todo.title)
        .onChange(of: todo.title) { _, _ in try? modelContext.save() }
        .onChange(of: todo.notes) { _, _ in try? modelContext.save() }
        .onChange(of: todo.isCompleted) { _, _ in try? modelContext.save() }
        .onChange(of: todo.dueAt) { _, _ in try? modelContext.save() }
    }

    /// What "no project" means here: none, or the one inherited from a parent.
    private var inheritedLabel: String {
        if todo.relatedProject == nil, let inherited = todo.parent?.inheritedProject {
            return "Same as parent (\(inherited.name))"
        }
        return todo.parent == nil ? "None" : "Same as parent"
    }

    /// The customer's projects and those of no customer, plus the current one.
    private var projectChoices: [Project] {
        guard let customer = todo.effectiveCustomer else { return projects }
        return projects.filter {
            $0.customer == nil || $0.customer?.id == customer.id || $0.id == todo.relatedProject?.id
        }
    }

    private var customerBinding: Binding<Customer?> {
        Binding(
            get: { todo.effectiveCustomer },
            set: { HanselActions.setTodoCustomer(todo, $0, context: modelContext) }
        )
    }

    private var projectBinding: Binding<Project?> {
        Binding(
            get: { todo.relatedProject },
            set: { HanselActions.setTodoProject(todo, $0, context: modelContext) }
        )
    }

    private var parentBinding: Binding<Todo?> {
        Binding(
            get: { todo.parent },
            set: { HanselActions.moveTodo(todo, under: $0, context: modelContext) }
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
        guard HanselActions.addTodo(title: newSubtaskTitle, parent: todo, context: modelContext) != nil else { return }
        newSubtaskTitle = ""
    }
}
