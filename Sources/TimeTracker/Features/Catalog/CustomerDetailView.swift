import SwiftUI
import SwiftData

struct CustomerDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var customer: Customer

    @State private var editingRule: ClassificationRule?
    /// What the user is typing; written to the customer only when no other customer
    /// already goes by one of them, so the list stays closed.
    @State private var aliasDraft: String = ""
    @State private var aliasConflict: CustomerMatcher.Conflict?
    @State private var nameConflict: CustomerMatcher.Conflict?
    /// The last name saved, put back if the page is left on a duplicate name.
    @State private var savedName: String = ""

    var body: some View {
        Form {
            Section("Customer") {
                TextField("Name", text: $customer.name)
                if let nameConflict {
                    Text(nameConflict.message).font(.caption).foregroundStyle(.red)
                }
                Toggle("Billable by default", isOn: $customer.defaultBillable)
                    .onChange(of: customer.defaultBillable) { _, _ in refreshCaches() }
            }
            Section("Aliases") {
                TextField("acme.com, ITX, #acme-rollout, jane@acme.com", text: $aliasDraft)
                    .onSubmit(commitAliases)
                if let aliasConflict {
                    Text(aliasConflict.message).font(.caption).foregroundStyle(.red)
                }
                Text("Other names this customer goes by, separated by commas: email domains, abbreviations, Slack channels (#name) and contacts. Type acronyms in capitals (AM, ANF): they then only count written in capitals. Meetings, messages and emails that mention them are attributed to this customer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep out of AI context", isOn: $customer.excludedFromContext)
                Text("Todos, meetings and messages of this customer are never gathered as context for AI assistants. Use it for personal matters.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !customer.excludedFromContext {
                DossierSection(dossier: $customer.dossier, updatedAt: customer.dossierUpdatedAt) {
                    customer.dossierUpdatedAt = Date()
                    try? modelContext.save()
                }
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
        .onChange(of: customer.name) { _, name in
            nameConflict = HanselActions.customerConflict(name: name, excluding: customer, context: modelContext)
            guard nameConflict == nil else { return }
            savedName = name
            try? modelContext.save()
        }
        .onChange(of: aliasDraft) { _, _ in commitAliases() }
        .onChange(of: customer.excludedFromContext) { _, _ in try? modelContext.save() }
        .onAppear {
            aliasDraft = customer.aliases
            savedName = customer.name
        }
        .onDisappear {
            // Leaving with a name another customer has would make a duplicate.
            guard nameConflict != nil else { return }
            customer.name = savedName
            try? modelContext.save()
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule)
        }
    }

    private func commitAliases() {
        aliasConflict = HanselActions.customerConflict(aliases: aliasDraft, excluding: customer, context: modelContext)
        guard aliasConflict == nil, customer.aliases != aliasDraft else { return }
        customer.aliases = aliasDraft
        try? modelContext.save()
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
