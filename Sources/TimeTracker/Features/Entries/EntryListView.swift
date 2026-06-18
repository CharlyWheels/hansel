import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct EntryListView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<TimeEntry> { $0.endAt != nil },
        sort: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
    ) private var entries: [TimeEntry]

    @State private var editingEntry: TimeEntry?

    var body: some View {
        VStack(alignment: .leading) {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No entries yet",
                    systemImage: "tray",
                    description: Text("Start a timer from the menu bar.")
                )
            } else {
                List {
                    ForEach(groupedByDay, id: \.date) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                entryRow(entry)
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
                            }
                            .onDelete { offsets in
                                delete(from: group.entries, offsets: offsets)
                            }
                        } header: {
                            dayHeader(group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Entries")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addEntry()
                } label: {
                    Label("New entry", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
            }
        }
        .sheet(item: $editingEntry) { entry in
            EntryEditorView(entry: entry)
                .frame(minWidth: 480, minHeight: 360)
        }
    }

    // MARK: - CSV

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "timetracker-\(df.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let iso = ISO8601DateFormatter()
        var rows: [String] = ["Title,Start,End,Duration (min),Role,Project,Customer,Billable,Source,Notes"]
        for e in entries {
            let dur = Int((e.duration ?? 0) / 60)
            let fields = [
                csvEscape(e.title),
                iso.string(from: e.startAt),
                e.endAt.map { iso.string(from: $0) } ?? "",
                String(dur),
                csvEscape(e.role?.name ?? ""),
                csvEscape(e.project?.name ?? ""),
                csvEscape(e.customer?.name ?? ""),
                e.billableCached ? "yes" : "no",
                e.source.rawValue,
                csvEscape(e.notes ?? "")
            ]
            rows.append(fields.joined(separator: ","))
        }
        try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        AppLogger.log("ui", level: .info, "csv_exported rows=\(rows.count - 1)")
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Row

    private func entryRow(_ entry: TimeEntry) -> some View {
        EntryRowView(entry: entry)
    }

    // MARK: - Grouping

    private struct DayGroup {
        let date: Date
        let entries: [TimeEntry]
    }

    private var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) {
            cal.startOfDay(for: $0.startAt)
        }
        return grouped
            .map { DayGroup(date: $0.key, entries: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private func dayHeader(_ group: DayGroup) -> some View {
        let total = group.entries.reduce(0) { $0 + ($1.duration ?? 0) }
        let billable = group.entries
            .filter { $0.billableCached }
            .reduce(0) { $0 + ($1.duration ?? 0) }
        return HStack {
            Text(group.date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.headline)
            Spacer()
            Text("\(DurationFormat.hoursMinutes(total)) · \(DurationFormat.hoursMinutes(billable)) billable")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func delete(from entries: [TimeEntry], offsets: IndexSet) {
        for i in offsets {
            modelContext.delete(entries[i])
        }
        try? modelContext.save()
    }

    private func addEntry() {
        let now = Date()
        let entry = TimeEntry(
            title: "",
            startAt: now.addingTimeInterval(-3600),
            endAt: now,
            isConfirmed: true,
            source: .manual
        )
        modelContext.insert(entry)
        try? modelContext.save()
        editingEntry = entry
    }
}
