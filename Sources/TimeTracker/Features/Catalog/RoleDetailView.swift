import SwiftUI
import SwiftData

struct RoleDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var role: Role

    @State private var editingRule: ClassificationRule?

    var body: some View {
        Form {
            Section("Role") {
                TextField("Name", text: $role.name)
                Toggle("Billable by default", isOn: $role.defaultBillable)
                    .onChange(of: role.defaultBillable) { _, _ in refreshCaches() }
            }
            Section {
                RulesSection(
                    rules: role.rules,
                    onAdd: addRule,
                    onEdit: { editingRule = $0 },
                    onDelete: deleteRule
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(role.name.isEmpty ? "Role" : role.name)
        .onChange(of: role.name) { _, _ in try? modelContext.save() }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule)
        }
    }

    private func addRule() {
        let rule = ClassificationRule(name: "New rule", targetRole: role)
        modelContext.insert(rule)
        try? modelContext.save()
        editingRule = rule
    }

    private func deleteRule(_ rule: ClassificationRule) {
        modelContext.delete(rule)
        try? modelContext.save()
    }

    private func refreshCaches() {
        let id = role.id
        HanselActions.refreshBillable(context: modelContext) { $0.role?.id == id }
    }
}
