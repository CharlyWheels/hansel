import SwiftUI
import SwiftData

struct CustomerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var customer: Customer

    @State private var editingRule: ClassificationRule?

    var body: some View {
        Form {
            Section("Customer") {
                TextField("Name", text: $customer.name)
                Toggle("Billable by default", isOn: $customer.defaultBillable)
                    .onChange(of: customer.defaultBillable) { _, _ in refreshCaches() }
            }
            Section("Email domains") {
                TextField("acme.com, acme.co.uk", text: $customer.emailDomains)
                Text("Meetings with people from these domains are attributed to this customer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                RulesSection(
                    rules: customer.rules,
                    onAdd: addRule,
                    onEdit: { editingRule = $0 },
                    onDelete: deleteRule
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(customer.name.isEmpty ? "Customer" : customer.name)
        .onChange(of: customer.name) { _, _ in try? modelContext.save() }
        .onChange(of: customer.emailDomains) { _, _ in try? modelContext.save() }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule)
        }
    }

    private func addRule() {
        let rule = ClassificationRule(name: "New rule", targetCustomer: customer)
        modelContext.insert(rule)
        try? modelContext.save()
        editingRule = rule
    }

    private func deleteRule(_ rule: ClassificationRule) {
        modelContext.delete(rule)
        try? modelContext.save()
    }

    private func refreshCaches() {
        let id = customer.id
        HanselActions.refreshBillable(context: modelContext) { $0.customer?.id == id }
    }
}
