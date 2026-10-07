import SwiftUI
import SwiftData

/// Edits a copy of the entry and writes it back only on Save, so Cancel really cancels.
///
/// Binding the form straight to the model meant every keystroke landed in the shared
/// context and autosave kept it, whatever button the user pressed. A new entry is passed
/// in un-inserted and only inserted on Save, so cancelling leaves nothing behind.
struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TimerController.self) private var controller

    let entry: TimeEntry

    @Query(sort: [SortDescriptor(\Role.name)]) private var roles: [Role]
    @Query(sort: [SortDescriptor(\Project.name)]) private var projects: [Project]
    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]
    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]

    @State private var title: String
    @State private var notes: String
    @State private var role: Role?
    @State private var project: Project?
    @State private var customer: Customer?
    @State private var todo: Todo?
    @State private var startAt: Date
    @State private var endAt: Date?
    @State private var confirmDelete = false

    init(entry: TimeEntry) {
        self.entry = entry
        _title = State(initialValue: entry.title)
        _notes = State(initialValue: entry.notes ?? "")
        _role = State(initialValue: entry.role)
        _project = State(initialValue: entry.project)
        _customer = State(initialValue: entry.customer)
        _todo = State(initialValue: entry.linkedTodo)
        _startAt = State(initialValue: entry.startAt)
        _endAt = State(initialValue: entry.endAt)
    }

    private var isNew: Bool { entry.modelContext == nil }
    private var isRunning: Bool { entry.endAt == nil }

    private var activeTodos: [Todo] {
        allTodos.filter { !$0.isCompleted || $0.id == todo?.id }
    }

    /// A running entry may not start in the future; a closed one may not end before
    /// it starts.
    private var isValid: Bool {
        if let endAt { return endAt >= startAt }
        return startAt <= Date()
    }

    var body: some View {
        Form {
            Section("Entry") {
                TextField("Title", text: $title)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section("Classification") {
                Picker("Role", selection: $role) {
                    Text("None").tag(Optional<Role>.none)
                    ForEach(roles) { role in Text(role.name).tag(Optional(role)) }
                }
                Picker("Project", selection: $project) {
                    Text("No project").tag(Optional<Project>.none)
                    ForEach(projects) { project in
                        Text(project.customer.map { "\(project.name) — \($0.name)" } ?? project.name)
                            .tag(Optional(project))
                    }
                }
                .onChange(of: project) { _, newProject in
                    // Auto-fill customer from project only when no customer is set yet,
                    // so a manual customer choice isn't silently overwritten.
                    if customer == nil, let c = newProject?.customer {
                        customer = c
                    }
                }
                Picker("Customer", selection: $customer) {
                    Text("None").tag(Optional<Customer>.none)
                    ForEach(customers) { c in Text(c.name).tag(Optional(c)) }
                }
                Picker("Todo", selection: $todo) {
                    Text("None").tag(Optional<Todo>.none)
                    ForEach(activeTodos) { todo in
                        Text(todo.breadcrumbPath).tag(Optional(todo))
                    }
                }
                LabeledContent("Billable", value: isBillable ? "Yes" : "No")
                    .foregroundStyle(isBillable ? .green : .secondary)
            }

            Section("Time") {
                if isRunning {
                    DatePicker("Start", selection: $startAt, in: ...Date())
                    LabeledContent("End") {
                        Label("Running", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                } else {
                    DatePicker("Start", selection: $startAt)
                    DatePicker("End", selection: Binding(
                        get: { endAt ?? startAt },
                        set: { endAt = $0 }
                    ), in: startAt...)
                    LabeledContent("Duration",
                                   value: DurationFormat.hoursMinutes(max(0, (endAt ?? startAt).timeIntervalSince(startAt))))
                }
                if !isValid {
                    Text("The end must be after the start.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if !isNew {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!isValid)
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(title.isEmpty ? "(untitled)" : title) — this can't be undone.")
        }
    }

    private func save() {
        guard isValid else { return }
        // Insert before touching relationships, so they are set between models that
        // already share a context.
        if isNew { modelContext.insert(entry) }
        entry.title = title
        entry.notes = notes.isEmpty ? nil : notes
        entry.role = role
        entry.project = project
        entry.customer = customer
        entry.linkedTodo = todo
        entry.startAt = startAt
        if !isRunning { entry.endAt = endAt }
        entry.refreshBillableCache()
        // An explicit save means a human vouched for this entry, so it becomes
        // eligible as a classification example.
        entry.isHumanConfirmed = true
        // Only an edit to the running entry should hold the arbiter off it.
        if isRunning, controller.runningEntry?.id == entry.id { controller.noteManualEdit() }
        try? modelContext.save()
        // A meeting shows the name its entry was corrected to.
        MeetingTitleSync.entrySaved(entry, context: modelContext)
        dismiss()
    }

    private func delete() {
        if controller.runningEntry?.id == entry.id {
            // The controller holds the running entry; deleting it behind the
            // controller's back leaves it pointing at a deleted model.
            controller.cancel()
        } else {
            modelContext.delete(entry)
            try? modelContext.save()
        }
        dismiss()
    }

    private var isBillable: Bool {
        BillableResolver.resolve(role: role, project: project, customer: customer)
    }
}
