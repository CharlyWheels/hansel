import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct AnalyticsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<TimeEntry> { $0.endAt != nil },
        sort: [SortDescriptor(\TimeEntry.startAt)]
    ) private var entries: [TimeEntry]
    @Query private var projects: [Project]

    enum Choice: String, CaseIterable, Identifiable {
        case today = "Today", thisWeek = "This week", lastWeek = "Last week"
        case thisMonth = "This month", lastMonth = "Last month", custom = "Custom"
        var id: String { rawValue }

        /// What the period is compared with, for "vs …" labels.
        var comparison: String {
            switch self {
            case .today: return "yesterday"
            case .thisWeek: return "last week"
            case .lastWeek: return "the week before"
            case .thisMonth: return "last month"
            case .lastMonth: return "the month before"
            case .custom: return "previous period"
            }
        }
    }

    @State private var choice: Choice = .thisWeek
    @State private var customFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customTo: Date = Date()
    @State private var snapshot: AnalyticsEngine.Snapshot?

    @State private var exportInProgress = false
    @State private var exportError: String?

    private var customPeriod: Period {
        let cal = Calendar.current
        let start = cal.startOfDay(for: min(customFrom, customTo))
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customFrom, customTo))) ?? customTo
        return .custom(from: start, to: end)
    }

    private var period: Period {
        switch choice {
        case .today: return .today
        case .thisWeek: return .thisWeek
        case .lastWeek: return .lastWeek
        case .thisMonth: return .thisMonth
        case .lastMonth: return .lastMonth
        case .custom: return customPeriod
        }
    }

    private var projectColors: [String: Color] {
        var colors = ["none": Color.gray.opacity(0.6)]
        for project in projects { colors[project.id.uuidString] = project.displayColor }
        return colors
    }

    /// Recomputed when the period or the entries change.
    private var reloadKey: String {
        let i = period.interval()
        return "\(i.start.timeIntervalSince1970)-\(i.end.timeIntervalSince1970)-\(entries.count)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Analytics", subtitle: periodSubtitle) {
                    exportMenu
                }
                periodBar
                if let snapshot {
                    let colors = projectColors
                    AnalyticsSummaryTiles(snapshot: snapshot, comparison: choice.comparison)
                    DaysChartCard(snapshot: snapshot, colors: colors)
                    BreakdownCard(snapshot: snapshot, colors: colors, comparison: choice.comparison)
                    HeatmapCard(snapshot: snapshot)
                    FocusCard(snapshot: snapshot)
                    MeetingsAnalyticsCard(snapshot: snapshot)
                    QualityCard(snapshot: snapshot)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(20)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Analytics")
        .task(id: reloadKey) { reload() }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func reload() {
        let interval = period.interval()
        let input = AnalyticsLoader.input(for: interval, context: modelContext)
        snapshot = AnalyticsEngine.snapshot(input, interval: interval)
    }

    private var periodSubtitle: String {
        guard let snapshot else { return "Where your time went" }
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        let current = DateInterval(start: snapshot.interval.start, end: snapshot.interval.end.addingTimeInterval(-1))
        let previous = DateInterval(start: snapshot.previousInterval.start,
                                    end: snapshot.previousInterval.end.addingTimeInterval(-1))
        return "\(f.string(from: current) ?? "") · compared with \(f.string(from: previous) ?? "")"
    }

    private var periodBar: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $choice) {
                ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if choice == .custom {
                DatePicker("From", selection: $customFrom, displayedComponents: [.date]).labelsHidden()
                Text("→").foregroundStyle(.secondary)
                DatePicker("To", selection: $customTo, displayedComponents: [.date]).labelsHidden()
            }
            Spacer()
        }
    }

    // MARK: - Export

    private var exportMenu: some View {
        Menu {
            Button("\(choice.rawValue) (shown)") { exportExcel(period: period) }
            Divider()
            Button("Today") { exportExcel(period: .today) }
            Button("This Week") { exportExcel(period: .thisWeek) }
            Button("Previous Week") { exportExcel(period: .lastWeek) }
            Button("This Month") { exportExcel(period: .thisMonth) }
            Button("Last Month") { exportExcel(period: .lastMonth) }
        } label: {
            if exportInProgress {
                ProgressView().controlSize(.small)
            } else {
                Label("Export Excel", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(exportInProgress || entries.isEmpty)
    }

    private func exportExcel(period: Period) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "timetracker-\(df.string(from: Date())).xlsx"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // Snapshot on the main actor: only plain values may cross into the detached task.
        let frozenReport = XLSXWriter.Snapshot(report: AnalyticsAggregator.report(entries: entries, period: period))
        exportInProgress = true
        Task.detached {
            do {
                try XLSXWriter.write(report: frozenReport, to: dest)
                AppLogger.log("ui", level: .info, "xlsx_exported path=\(dest.path)")
                await MainActor.run { exportInProgress = false }
            } catch {
                AppLogger.log("ui", level: .error, "xlsx_export_failed: \(error.localizedDescription)")
                await MainActor.run {
                    exportInProgress = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}
