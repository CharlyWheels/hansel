import SwiftUI
import SwiftData

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var project: Project

    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]
    @State private var editingRule: ClassificationRule?

    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $project.name)
                Picker("Customer", selection: $project.customer) {
                    Text("No customer").tag(Optional<Customer>.none)
                    ForEach(customers) { c in Text(c.name).tag(Optional(c)) }
                }
                Toggle("Billable by default", isOn: $project.defaultBillable)
                    .onChange(of: project.defaultBillable) { _, _ in refreshCaches() }
                colorPickerRow
            }
            Section("Description") {
                TextField("What is this project? Client, repos, keywords…", text: $project.details, axis: .vertical)
                    .lineLimit(2...5)
                    .onSubmit { try? modelContext.save() }
                Text("Sent to the AI with the project list, so it can tell your projects apart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                RulesSection(
                    rules: project.rules,
                    onAdd: addRule,
                    onEdit: { editingRule = $0 },
                    onDelete: deleteRule
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name.isEmpty ? "Project" : project.name)
        .onChange(of: project.name) { _, _ in try? modelContext.save() }
        .onChange(of: project.details) { _, _ in try? modelContext.save() }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule)
        }
    }

    private var colorPickerRow: some View {
        HStack {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { project.displayColor },
                    set: {
                        project.colorHex = $0.hexString
                        try? modelContext.save()
                    }
                ),
                supportsOpacity: false
            )
            if project.colorHex != nil {
                Button("Reset") {
                    project.colorHex = nil
                    try? modelContext.save()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private func addRule() {
        let rule = ClassificationRule(name: "New rule", targetProject: project)
        modelContext.insert(rule)
        try? modelContext.save()
        editingRule = rule
    }

    private func deleteRule(_ rule: ClassificationRule) {
        modelContext.delete(rule)
        try? modelContext.save()
    }

    private func refreshCaches() {
        let id = project.id
        HanselActions.refreshBillable(context: modelContext) { $0.project?.id == id }
    }
}
