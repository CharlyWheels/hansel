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

    @State private var customFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customTo: Date = Date()

    @State private var exportInProgress = false
    @State private var exportError: String?

    private var customPeriod: Period {
        let cal = Calendar.current
        let start = cal.startOfDay(for: customFrom)
        let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: customTo) ?? customTo
        return .custom(from: start, to: end)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PieChartSection(title: "Today", entries: entries, period: .today)
                PieChartSection(title: "This Week", entries: entries, period: .thisWeek)
                PieChartSection(title: "Previous Week", entries: entries, period: .lastWeek)
                PieChartSection(title: "Last Month", entries: entries, period: .lastMonth)
                PieChartSection(
                    title: "Custom",
                    entries: entries,
                    period: customPeriod,
                    customHeader: AnyView(customRangePicker)
                )
            }
            .padding()
        }
        .navigationTitle("Analytics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                exportMenu
            }
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var customRangePicker: some View {
        HStack(spacing: 8) {
            Text("Range").font(.caption).foregroundStyle(.secondary)
            DatePicker("From", selection: $customFrom, displayedComponents: [.date])
                .labelsHidden()
            Text("→").foregroundStyle(.secondary)
            DatePicker("To", selection: $customTo, displayedComponents: [.date])
                .labelsHidden()
            Spacer()
        }
    }

    // MARK: - Export

    private var exportMenu: some View {
        Menu {
            Button("Today") { exportExcel(period: .today) }
            Button("This Week") { exportExcel(period: .thisWeek) }
            Button("Previous Week") { exportExcel(period: .lastWeek) }
            Button("Last Month") { exportExcel(period: .lastMonth) }
            Button("Custom range") { exportExcel(period: customPeriod) }
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

        let frozenReport = AnalyticsAggregator.report(entries: entries, period: period)
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
