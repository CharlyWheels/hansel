import SwiftUI
import SwiftData

struct RolesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Role.name)]) private var roles: [Role]

    @State private var newName: String = ""
    @State private var newBillable: Bool = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                addRow.padding()
                Divider()
                List {
                    ForEach(roles) { role in
                        NavigationLink(value: role) {
                            rowSummary(role)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.inset)
            }
            .navigationTitle("Roles")
            .navigationDestination(for: Role.self) { role in
                RoleDetailView(role: role)
            }
        }
    }

    private var addRow: some View {
        HStack {
            TextField("Role name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Toggle("Billable", isOn: $newBillable)
            Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func rowSummary(_ role: Role) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(role.name.isEmpty ? "(unnamed)" : role.name)
                HStack(spacing: 6) {
                    billableBadge(role.defaultBillable)
                    rulesBadge(count: role.rules.count)
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
        modelContext.insert(Role(name: trimmed, defaultBillable: newBillable))
        try? modelContext.save()
        newName = ""
        newBillable = true
    }

    private func delete(offsets: IndexSet) {
        for i in offsets { modelContext.delete(roles[i]) }
        try? modelContext.save()
        let all = (try? modelContext.fetch(FetchDescriptor<TimeEntry>())) ?? []
        for entry in all { entry.refreshBillableCache() }
        try? modelContext.save()
    }
}
