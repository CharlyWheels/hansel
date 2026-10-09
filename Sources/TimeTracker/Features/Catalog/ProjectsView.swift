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
                VStack(alignment: .leading, spacing: 12) {
                    PageHeader("Projects", subtitle: "\(projects.count) project\(projects.count == 1 ? "" : "s")")
                    addRow
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
                SuggestedRulesSection(projects: projects)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                Divider()
                List {
                    ForEach(projects) { project in
                        NavigationLink(value: project) {
                            rowSummary(project)
                        }
                        .contextMenu {
                            Button("Delete…", role: .destructive) {
                                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                                    pendingDelete = IndexSet(integer: index)
                                }
                            }
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
        AddField("Add a project", text: $newName, onAdd: add) {
            Picker("Customer", selection: $newCustomer) {
                Text("No customer").tag(Optional<Customer>.none)
                ForEach(customers) { c in Text(c.name).tag(Optional(c)) }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Billable", isOn: $newBillable).toggleStyle(.checkbox)
        }
    }

    private func rowSummary(_ project: Project) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(project.displayColor.gradient)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name.isEmpty ? "(unnamed)" : project.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let customer = project.customer {
                        Chip(text: customer.name, systemImage: "person.2")
                    }
                    BillableChip(billable: project.defaultBillable)
                    if !project.rules.isEmpty {
                        Chip(text: "\(project.rules.count) rule\(project.rules.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
                    }
                }
                if !project.details.isEmpty {
                    Text(project.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            hours(CatalogStats.last30Days(project.entries))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func hours(_ seconds: TimeInterval) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(seconds > 0 ? DurationFormat.hoursMinutes(seconds) : "—").monospacedDigit()
            Text("last 30 days").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func add() {
        guard HanselActions.addProject(
            name: newName, customer: newCustomer, defaultBillable: newBillable, context: modelContext
        ) != nil else { return }
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
