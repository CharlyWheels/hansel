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
                VStack(alignment: .leading, spacing: 12) {
                    PageHeader("Customers", subtitle: "\(customers.count) customer\(customers.count == 1 ? "" : "s")")
                    addRow
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
                Divider()
                List {
                    ForEach(customers) { customer in
                        NavigationLink(value: customer) {
                            rowSummary(customer)
                        }
                        .contextMenu {
                            Button("Delete…", role: .destructive) {
                                if let index = customers.firstIndex(where: { $0.id == customer.id }) {
                                    pendingDelete = IndexSet(integer: index)
                                }
                            }
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
        AddField("Add a customer", text: $newName, onAdd: add) {
            Toggle("Billable", isOn: $newBillable).toggleStyle(.checkbox)
        }
    }

    private func rowSummary(_ customer: Customer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(customer.name.isEmpty ? "(unnamed)" : customer.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Chip(text: "\(customer.projects.count) project\(customer.projects.count == 1 ? "" : "s")", systemImage: "folder")
                    BillableChip(billable: customer.defaultBillable)
                    if !customer.emailDomains.isEmpty {
                        Chip(text: customer.emailDomains, systemImage: "at")
                    }
                    if !customer.rules.isEmpty {
                        Chip(text: "\(customer.rules.count) rule\(customer.rules.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                let seconds = CatalogStats.last30Days(customer.entries)
                Text(seconds > 0 ? DurationFormat.hoursMinutes(seconds) : "—").monospacedDigit()
                Text("last 30 days").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
