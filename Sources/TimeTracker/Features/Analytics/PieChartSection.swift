import SwiftUI
import Charts

enum BreakdownDimension: String, CaseIterable, Identifiable {
    case role = "Role"
    case project = "Project"
    case customer = "Customer"

    var id: String { rawValue }
}

struct PieChartSection: View {
    let title: String
    let entries: [TimeEntry]
    let period: Period
    let customHeader: AnyView?

    @State private var groupBy: BreakdownDimension = .project

    init(
        title: String,
        entries: [TimeEntry],
        period: Period,
        customHeader: AnyView? = nil,
        defaultGroupBy: BreakdownDimension = .project
    ) {
        self.title = title
        self.entries = entries
        self.period = period
        self.customHeader = customHeader
        _groupBy = State(initialValue: defaultGroupBy)
    }

    private var report: AnalyticsReport {
        AnalyticsAggregator.report(entries: entries, period: period)
    }

    private var rows: [BreakdownRow] {
        switch groupBy {
        case .role: return report.byRole
        case .project: return report.byProject
        case .customer: return report.byCustomer
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let customHeader { customHeader }
            summaryRow
            groupByPicker
            chartAndLegend
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3).fontWeight(.semibold)
            Spacer()
            Text(rangeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var rangeLabel: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        let start = report.interval.start
        // Use end - 1 second so "end-exclusive" interval shows as the inclusive last day.
        let end = report.interval.end.addingTimeInterval(-1)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return df.string(from: start)
        }
        return "\(df.string(from: start)) → \(df.string(from: end))"
    }

    // MARK: - Summary

    private var summaryRow: some View {
        HStack(spacing: 20) {
            statBlock(label: "Total", value: DurationFormat.hoursMinutes(report.totalSeconds))
            statBlock(
                label: "Billable",
                value: DurationFormat.hoursMinutes(report.billableSeconds),
                sublabel: billablePercentLabel,
                valueColor: report.billableSeconds > 0 ? .green : .secondary
            )
            statBlock(label: "Entries", value: "\(report.entryCount)")
            Spacer()
        }
    }

    private var billablePercentLabel: String {
        guard report.totalSeconds > 0 else { return "0%" }
        let pct = Int((report.billableSeconds / report.totalSeconds * 100).rounded())
        return "\(pct)% of total"
    }

    private func statBlock(
        label: String,
        value: String,
        sublabel: String? = nil,
        valueColor: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit().foregroundStyle(valueColor)
            if let sublabel {
                Text(sublabel).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Group by picker

    private var groupByPicker: some View {
        HStack(spacing: 8) {
            Text("Group by").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $groupBy) {
                ForEach(BreakdownDimension.allCases) { dim in
                    Text(dim.rawValue).tag(dim)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
        }
    }

    // MARK: - Chart + legend

    @ViewBuilder
    private var chartAndLegend: some View {
        if rows.isEmpty {
            Text("No entries in this period.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 32)
        } else {
            HStack(alignment: .top, spacing: 24) {
                donut
                    .frame(width: 220, height: 220)
                legend
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var donut: some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value("Hours", row.total),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(by: .value("Name", row.name))
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 2) {
                Text(DurationFormat.hoursMinutes(report.totalSeconds))
                    .font(.title3.monospacedDigit())
                    .fontWeight(.semibold)
                Text("total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(legendColor(for: index))
                        .frame(width: 10, height: 10)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(DurationFormat.hoursMinutes(row.total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("(\(Int((row.share * 100).rounded()))%)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
        }
    }

    /// Match Swift Charts' default categorical palette order.
    private func legendColor(for index: Int) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow, .indigo, .mint, .cyan, .brown]
        return palette[index % palette.count]
    }
}
