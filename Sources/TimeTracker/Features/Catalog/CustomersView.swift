import SwiftUI
import SwiftData

struct CustomersView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]

    @State private var newName: String = ""
    @State private var newBillable: Bool = true
    @State private var pendingDelete: IndexSet?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                addRow.padding()
                Divider()
                List {
                    ForEach(customers) { customer in
                        NavigationLink(value: customer) {
                            rowSummary(customer)
                        }
                    }
                    .onDelete { pendingDelete = $0 }
                }
                .listStyle(.inset)
                .confirmingDelete($pendingDelete, noun: "customer",
                                  affectedEntries: { $0.reduce(0) { sum, i in sum + customers[i].entries.count } },
                                  perform: delete)
            }
            .navigationTitle("Customers")
            .navigationDestination(for: Customer.self) { customer in
                CustomerDetailView(customer: customer)
            }
        }
    }

    private var addRow: some View {
        HStack {
            TextField("Customer name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Toggle("Billable", isOn: $newBillable)
            Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func rowSummary(_ customer: Customer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(customer.name.isEmpty ? "(unnamed)" : customer.name)
                HStack(spacing: 6) {
                    Text("\(customer.projects.count) project\(customer.projects.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    billableBadge(customer.defaultBillable)
                    rulesBadge(count: customer.rules.count)
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
        modelContext.insert(Customer(name: trimmed, defaultBillable: newBillable))
        try? modelContext.save()
        newName = ""
        newBillable = true
    }

    private func delete(offsets: IndexSet) {
        for i in offsets { modelContext.delete(customers[i]) }
        // Entries keep their billable flag: it records what the time was when it was
        // tracked, and deleting a catalog row must not rewrite past invoices.
        try? modelContext.save()
    }
}
