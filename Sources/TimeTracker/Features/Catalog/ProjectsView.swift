import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Project.name)]) private var projects: [Project]
    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]

    @State private var newName: String = ""
    @State private var newCustomer: Customer?
    @State private var newBillable: Bool = true
    @State private var pendingDelete: IndexSet?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                addRow.padding()
                Divider()
                List {
                    ForEach(projects) { project in
                        NavigationLink(value: project) {
                            rowSummary(project)
                        }
                    }
                    .onDelete { pendingDelete = $0 }
                }
                .listStyle(.inset)
                .confirmingDelete($pendingDelete, noun: "project",
                                  affectedEntries: { $0.reduce(0) { sum, i in sum + projects[i].entries.count } },
                                  perform: delete)
            }
            .navigationTitle("Projects")
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(project: project)
            }
        }
    }

    private var addRow: some View {
        HStack {
            TextField("Project name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Picker("Customer", selection: $newCustomer) {
                Text("No customer").tag(Optional<Customer>.none)
                ForEach(customers) { c in Text(c.name).tag(Optional(c)) }
            }
            .frame(maxWidth: 180)
            Toggle("Billable", isOn: $newBillable)
            Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func rowSummary(_ project: Project) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(project.displayColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name.isEmpty ? "(unnamed)" : project.name)
                HStack(spacing: 6) {
                    if let customer = project.customer {
                        Text(customer.name).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No customer").font(.caption).foregroundStyle(.tertiary)
                    }
                    billableBadge(project.defaultBillable)
                    rulesBadge(count: project.rules.count)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func billableBadge(_ on: Bool) -> some View {
        Text(on ? "Billable" : "Non-billable")
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background((on ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(on ? .green : .secondary)
    }

    private func rulesBadge(count: Int) -> some View {
        Group {
            if count > 0 {
                Label("\(count) rule\(count == 1 ? "" : "s")", systemImage: "text.badge.checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }

    private func add() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let p = Project(name: trimmed, customer: newCustomer, defaultBillable: newBillable)
        modelContext.insert(p)
        try? modelContext.save()
        newName = ""
        newBillable = true
    }

    private func delete(offsets: IndexSet) {
        for i in offsets { modelContext.delete(projects[i]) }
        // Entries keep their billable flag: it records what the time was when it was
        // tracked, and deleting a catalog row must not rewrite past invoices.
        try? modelContext.save()
    }
}
