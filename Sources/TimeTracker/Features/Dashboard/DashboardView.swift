import SwiftUI
import SwiftData

/// The first page: today at a glance, then the week, what is waiting for the user, and
/// the latest entries.
struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(MainWindowRouter.self) private var router
    @Environment(TimerController.self) private var controller

    @Query(
        filter: #Predicate<TimeEntry> { $0.endAt != nil },
        sort: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
    ) private var entries: [TimeEntry]

    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]
    @Query(TodoProposal.pendingDescriptor) private var proposals: [TodoProposal]

    @State private var editingEntry: TimeEntry?

    private var openTodos: [Todo] { allTodos.filter { !$0.isCompleted && $0.parent == nil } }
    private var completedThisWeek: Int {
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return allTodos.filter { $0.isCompleted && ($0.completedAt ?? .distantPast) >= weekStart }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greeting
                todayCard
                statTiles
                HStack(alignment: .top, spacing: Theme.spacing) {
                    VStack(spacing: Theme.spacing) {
                        topThisWeek
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: Theme.spacing) {
                        if !proposals.isEmpty { proposalsCard }
                        todosCard
                    }
                    .frame(maxWidth: .infinity)
                }
                recentCard
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dashboard")
        .sheet(item: $editingEntry) { entry in
            EntryEditorView(entry: entry)
                .frame(minWidth: 480, minHeight: 360)
        }
    }

    // MARK: - Today

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greetingText).font(.largeTitle.weight(.semibold))
            Text(Date().formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary)
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = OwnerMatcher.userNames().first?.split(separator: " ").first.map(String.init) ?? ""
        let part = hour < 12 ? "Good morning" : hour < 19 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? part : "\(part), \(name)"
    }

    private var todayCard: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = TodaySummary.load(context: modelContext, now: context.date)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader("Today", systemImage: "sun.max")
                        Text(DurationFormat.hoursMinutes(today.strip.trackedSeconds))
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }
                    DayStrip(model: today.strip, height: 22) { today.colors[$0] ?? .gray }
                    HStack(spacing: 14) {
                        Label("\(today.entryCount) entr\(today.entryCount == 1 ? "y" : "ies")", systemImage: "list.bullet")
                        Label("\(today.billablePercent)% billable", systemImage: "dollarsign.circle")
                        if let running = controller.runningEntry {
                            Label("Now: \(running.title.isEmpty ? "(untitled)" : running.title)", systemImage: "record.circle")
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Open timeline") { router.selection = .timeline }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Numbers

    private var statTiles: some View {
        let week = AnalyticsAggregator.report(entries: entries, period: .thisWeek)
        let month = AnalyticsAggregator.report(entries: entries, period: .thisMonth)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.spacing), count: 4),
                         spacing: Theme.spacing) {
            StatTile(value: DurationFormat.hoursMinutes(week.totalSeconds), label: "This week",
                     systemImage: "calendar", tint: .blue)
            StatTile(value: percent(week), label: "Billable this week",
                     systemImage: "dollarsign.circle", tint: .green)
            StatTile(value: DurationFormat.hoursMinutes(month.totalSeconds), label: "This month",
                     systemImage: "calendar.badge.clock", tint: .purple)
            StatTile(value: "\(openTodos.count)", label: completedThisWeek > 0 ? "Open todos · \(completedThisWeek) done this week" : "Open todos",
                     systemImage: "checklist", tint: .orange)
        }
    }

    private func percent(_ report: AnalyticsReport) -> String {
        guard report.totalSeconds > 0 else { return "—" }
        return "\(Int((report.billableSeconds / report.totalSeconds * 100).rounded()))%"
    }

    private var topThisWeek: some View {
        let week = AnalyticsAggregator.report(entries: entries, period: .thisWeek)
        let rows = Array(week.byProject.prefix(6))
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("This week by project", systemImage: "chart.bar") {
                    Button("Analytics") { router.selection = .analytics }.buttonStyle(.link).font(.caption)
                }
                if rows.isEmpty {
                    Text("Nothing tracked this week yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.name).lineLimit(1)
                                Spacer()
                                Text(DurationFormat.hoursMinutes(row.total))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            GeometryReader { geo in
                                Capsule().fill(Color.primary.opacity(0.07))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(projectColor(row.id).gradient)
                                            .frame(width: max(4, geo.size.width * row.share))
                                    }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
    }

    private func projectColor(_ id: UUID) -> Color {
        entries.first { $0.project?.id == id }?.project?.displayColor ?? .gray
    }

    // MARK: - Waiting for the user

    private var proposalsCard: some View {
        Card(tint: .accentColor) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Proposed from meetings", systemImage: "tray.and.arrow.down") {
                    Text("\(proposals.count)").font(.callout.weight(.semibold))
                }
                ForEach(proposals.prefix(3)) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.callout).lineLimit(1)
                        Text([p.meetingTitle, p.saidBy].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button("Review in Todos") { router.selection = .todos }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var todosCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Open todos", systemImage: "checklist") {
                    Button("All") { router.selection = .todos }.buttonStyle(.link).font(.caption)
                }
                if openTodos.isEmpty {
                    Text("Nothing open. Add one from the menu bar.").foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(openTodos.prefix(6)) { todo in
                        HStack(spacing: 8) {
                            Button {
                                todo.isCompleted = true
                                todo.completedAt = Date()
                                try? modelContext.save()
                            } label: { Image(systemName: "circle").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                            .help("Mark done")
                            Text(todo.title.isEmpty ? "(untitled)" : todo.title)
                                .lineLimit(1)
                                .foregroundStyle(todo.inheritedDisplayColor ?? .primary)
                            Spacer()
                            if let project = todo.inheritedProject {
                                Chip(text: project.name, color: project.displayColor)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    // MARK: - Recent

    private var recentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Recent entries", systemImage: "clock") {
                    Button("All entries") { router.selection = .entries }.buttonStyle(.link).font(.caption)
                }
                if entries.isEmpty {
                    Text("No entries yet. Start a timer from the menu bar.").foregroundStyle(.secondary)
                } else {
                    ForEach(entries.prefix(8)) { entry in
                        Button { editingEntry = entry } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(entry.displayColor).frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title.isEmpty ? "(untitled)" : entry.title).lineLimit(1)
                                    Text([entry.project?.name, entry.customer?.name].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(entry.startAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let d = entry.duration {
                                    Text(DurationFormat.hoursMinutes(d))
                                        .font(.callout.monospacedDigit())
                                        .frame(width: 60, alignment: .trailing)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if entry.id != entries.prefix(8).last?.id { Divider() }
                    }
                }
            }
        }
    }
}
