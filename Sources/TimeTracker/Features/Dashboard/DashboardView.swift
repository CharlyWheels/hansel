import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<TimeEntry> { $0.endAt != nil },
        sort: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
    ) private var entries: [TimeEntry]

    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]

    @State private var editingEntry: TimeEntry?

    private var activeTodos: [Todo] {
        allTodos.filter { !$0.isCompleted }
    }
    private var activeRootTodos: [Todo] {
        activeTodos.filter { $0.parent == nil }
    }
    private var activeSubtaskCount: Int {
        activeTodos.count - activeRootTodos.count
    }
    private var completedThisWeek: Int {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return allTodos.filter {
            $0.isCompleted && ($0.completedAt ?? .distantPast) >= weekStart
        }.count
    }

    private var todayReport: AnalyticsReport {
        AnalyticsAggregator.report(entries: entries, period: .today)
    }
    private var weekReport: AnalyticsReport {
        AnalyticsAggregator.report(entries: entries, period: .thisWeek)
    }
    private var monthReport: AnalyticsReport {
        AnalyticsAggregator.report(entries: entries, period: .thisMonth)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                cardGrid
                todosCardRow
                topRow
                activeTodosSection
                recentEntriesSection
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        .sheet(item: $editingEntry) { entry in
            EntryEditorView(entry: entry)
                .frame(minWidth: 480, minHeight: 360)
        }
    }

    // MARK: - Todos cards

    private var todosCardRow: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                summaryCard(
                    title: "Active todos",
                    value: "\(activeRootTodos.count)",
                    sublabel: activeSubtaskCount == 0
                        ? "no subtasks"
                        : "\(activeSubtaskCount) open subtask\(activeSubtaskCount == 1 ? "" : "s")",
                    tint: .orange
                )
                summaryCard(
                    title: "Completed this week",
                    value: "\(completedThisWeek)",
                    sublabel: completedThisWeek == 0 ? "—" : "todos finished",
                    tint: .green
                )
                summaryCard(
                    title: "Linked entries",
                    value: "\(linkedEntryCount)",
                    sublabel: "entries attached to a todo",
                    tint: .accentColor
                )
            }
        }
    }

    private var linkedEntryCount: Int {
        entries.filter { $0.linkedTodo != nil }.count
    }

    // MARK: - Active todos list

    private var activeTodosSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active todos").font(.headline)
            if activeRootTodos.isEmpty {
                Text("No active todos — add one from the Todos page or the menu bar.")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                VStack(spacing: 2) {
                    ForEach(activeRootTodos.prefix(5)) { todo in
                        todoRow(todo)
                        Divider()
                    }
                }
            }
        }
    }

    private func todoRow(_ todo: Todo) -> some View {
        let totalSub = todo.subtasks.count
        let doneSub = todo.subtasks.filter(\.isCompleted).count
        let project = todo.inheritedProject
        return HStack(spacing: 8) {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title.isEmpty ? "(untitled)" : todo.title)
                    .foregroundStyle(project?.displayColor ?? .primary)
                if let project {
                    Text(project.name)
                        .font(.caption2)
                        .foregroundStyle(project.displayColor)
                }
            }
            Spacer()
            if totalSub > 0 {
                Text("\(doneSub)/\(totalSub)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Cards

    private var cardGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                summaryCard(
                    title: "Today — Total",
                    value: DurationFormat.hoursMinutes(todayReport.totalSeconds),
                    sublabel: "\(todayReport.entryCount) entries",
                    tint: .accentColor
                )
                summaryCard(
                    title: "Today — Billable",
                    value: DurationFormat.hoursMinutes(todayReport.billableSeconds),
                    sublabel: billablePct(todayReport),
                    tint: .green
                )
                summaryCard(
                    title: "This Week — Total",
                    value: DurationFormat.hoursMinutes(weekReport.totalSeconds),
                    sublabel: "\(weekReport.entryCount) entries",
                    tint: .accentColor
                )
                summaryCard(
                    title: "This Week — Billable",
                    value: DurationFormat.hoursMinutes(weekReport.billableSeconds),
                    sublabel: billablePct(weekReport),
                    tint: .green
                )
                summaryCard(
                    title: "This Month — Total",
                    value: DurationFormat.hoursMinutes(monthReport.totalSeconds),
                    sublabel: "\(monthReport.entryCount) entries",
                    tint: .accentColor
                )
                summaryCard(
                    title: "This Month — Billable",
                    value: DurationFormat.hoursMinutes(monthReport.billableSeconds),
                    sublabel: billablePct(monthReport),
                    tint: .green
                )
            }
        }
    }

    private func summaryCard(title: String, value: String, sublabel: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(tint)
            Text(sublabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func billablePct(_ report: AnalyticsReport) -> String {
        guard report.totalSeconds > 0 else { return "0%" }
        let pct = Int((report.billableSeconds / report.totalSeconds * 100).rounded())
        return "\(pct)% of total"
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(alignment: .top, spacing: 20) {
            topItemBlock(
                title: "Top customer this month",
                row: monthReport.byCustomer.first
            )
            topItemBlock(
                title: "Top project this month",
                row: monthReport.byProject.first
            )
        }
    }

    @ViewBuilder
    private func topItemBlock(title: String, row: BreakdownRow?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let row {
                Text(row.name).font(.title3)
                Text("\(DurationFormat.hoursMinutes(row.total)) · \(Int((row.share * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").font(.title3).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recent

    private var recentEntriesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent entries").font(.headline)
            if entries.isEmpty {
                Text("No entries yet — start a timer from the menu bar.")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                VStack(spacing: 2) {
                    ForEach(entries.prefix(10)) { entry in
                        EntryRowView(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { editingEntry = entry }
                            .contextMenu {
                                Button("Edit") { editingEntry = entry }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    modelContext.delete(entry)
                                    try? modelContext.save()
                                }
                            }
                        Divider()
                    }
                }
            }
        }
    }
}
