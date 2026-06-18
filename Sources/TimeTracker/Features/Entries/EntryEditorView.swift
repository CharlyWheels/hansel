import SwiftUI
import SwiftData

struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var entry: TimeEntry

    @Query(sort: [SortDescriptor(\Role.name)]) private var roles: [Role]
    @Query(sort: [SortDescriptor(\Project.name)]) private var projects: [Project]
    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]
    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]

    private var activeTodos: [Todo] {
        allTodos.filter { !$0.isCompleted }
    }

    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Entry") {
                TextField("Title", text: $entry.title)
                TextField("Notes", text: Binding(
                    get: { entry.notes ?? "" },
                    set: { entry.notes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .lineLimit(2...6)
            }

            Section("Classification") {
                Picker("Role", selection: $entry.role) {
                    Text("None").tag(Optional<Role>.none)
                    ForEach(roles) { role in Text(role.name).tag(Optional(role)) }
                }
                Picker("Project", selection: $entry.project) {
                    Text("No project").tag(Optional<Project>.none)
                    ForEach(projects) { project in
                        Text(project.customer != nil ? "\(project.name) — \(project.customer!.name)" : project.name)
                            .tag(Optional(project))
                    }
                }
                .onChange(of: entry.project) { _, newProject in
                    // Auto-fill customer from project only when no customer is set yet,
                    // so a manual customer choice isn't silently overwritten.
                    if entry.customer == nil, let c = newProject?.customer {
                        entry.customer = c
                    }
                }
                Picker("Customer", selection: $entry.customer) {
                    Text("None").tag(Optional<Customer>.none)
                    ForEach(customers) { c in Text(c.name).tag(Optional(c)) }
                }
                Picker("Todo", selection: $entry.linkedTodo) {
                    Text("None").tag(Optional<Todo>.none)
                    ForEach(activeTodos) { todo in
                        Text(todo.breadcrumbPath).tag(Optional(todo))
                    }
                }
                LabeledContent("Billable", value: isBillable ? "Yes" : "No")
                    .foregroundStyle(isBillable ? .green : .secondary)
            }

            Section("Time") {
                DatePicker("Start", selection: $entry.startAt)
                if entry.endAt == nil {
                    LabeledContent("End") {
                        Label("Running", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                } else {
                    DatePicker("End", selection: Binding(
                        get: { entry.endAt ?? Date() },
                        set: { entry.endAt = $0 }
                    ))
                }
                if let d = entry.duration {
                    LabeledContent("Duration", value: DurationFormat.hoursMinutes(d))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    entry.refreshBillableCache()
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                modelContext.delete(entry)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(entry.title.isEmpty ? "(untitled)" : entry.title) — this can't be undone.")
        }
    }

    private var isBillable: Bool {
        BillableResolver.resolve(role: entry.role, project: entry.project, customer: entry.customer)
    }
}
