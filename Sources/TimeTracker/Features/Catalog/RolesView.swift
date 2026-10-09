import SwiftUI
import SwiftData

struct RolesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Role.name)]) private var roles: [Role]

    @State private var newName: String = ""
    @State private var newBillable: Bool = true
    @State private var pendingDelete: IndexSet?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    PageHeader("Roles", subtitle: "\(roles.count) role\(roles.count == 1 ? "" : "s")")
                    addRow
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
                Divider()
                List {
                    ForEach(roles) { role in
                        NavigationLink(value: role) {
                            rowSummary(role)
                        }
                        .contextMenu {
                            Button("Delete…", role: .destructive) {
                                if let index = roles.firstIndex(where: { $0.id == role.id }) {
                                    pendingDelete = IndexSet(integer: index)
                                }
                            }
                        }
                    }
                    .onDelete { pendingDelete = $0 }
                }
                .listStyle(.inset)
                .confirmingDelete($pendingDelete, noun: "role",
                                  affectedEntries: { $0.reduce(0) { sum, i in sum + roles[i].entries.count } },
                                  perform: delete)
            }
            .navigationTitle("Roles")
            .navigationDestination(for: Role.self) { role in
                RoleDetailView(role: role)
            }
        }
    }

    private var addRow: some View {
        AddField("Add a role", text: $newName, onAdd: add) {
            Toggle("Billable", isOn: $newBillable).toggleStyle(.checkbox)
        }
    }

    private func rowSummary(_ role: Role) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(role.name.isEmpty ? "(unnamed)" : role.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    BillableChip(billable: role.defaultBillable)
                    if !role.rules.isEmpty {
                        Chip(text: "\(role.rules.count) rule\(role.rules.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                let seconds = CatalogStats.last30Days(role.entries)
                Text(seconds > 0 ? DurationFormat.hoursMinutes(seconds) : "—").monospacedDigit()
                Text("last 30 days").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func add() {
        guard HanselActions.addRole(name: newName, defaultBillable: newBillable, context: modelContext) != nil else { return }
        newName = ""
        newBillable = true
    }

    private func delete(offsets: IndexSet) {
        for i in offsets { modelContext.delete(roles[i]) }
        // Entries keep their billable flag: it records what the time was when it was
        // tracked, and deleting a catalog row must not rewrite past invoices.
        try? modelContext.save()
    }
}
