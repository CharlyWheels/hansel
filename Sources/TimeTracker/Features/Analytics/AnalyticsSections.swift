import SwiftUI
import Charts

// MARK: - Small pieces

/// "↑ 12% vs last week", coloured by whether more is good.
struct DeltaLabel: View {
    let delta: AnalyticsEngine.Delta
    var comparison: String
    var higherIsGood = true
    /// Just "↗ 21%" or "new", for table cells.
    var compact = false

    var body: some View {
        if let change = delta.change {
            let up = change >= 0
            let good = up == higherIsGood
            let amount = "\(Int((abs(change) * 100).rounded()))%"
            Label(compact ? amount : "\(amount) vs \(comparison)",
                  systemImage: up ? "arrow.up.right" : "arrow.down.right")
                .font(.caption)
                .foregroundStyle(abs(change) < 0.03 ? Color.secondary : (good ? Color.green : Color.orange))
        } else {
            Text(delta.previous == 0 && delta.current > 0 ? (compact ? "new" : "nothing in \(comparison)") : " ")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// A tile with a big value and its change.
struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var delta: AnalyticsEngine.Delta? = nil
    var comparison: String = ""
    var higherIsGood = true
    var footnote: String? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .tint(tint)
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let delta {
                    DeltaLabel(delta: delta, comparison: comparison, higherIsGood: higherIsGood)
                } else if let footnote {
                    Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Horizontal bars for a ranked list (apps, sites, people…).
struct RankedBars: View {
    let items: [AnalyticsEngine.Ranked]
    var color: Color = .accentColor
    var empty: String = "No data for this period."

    var body: some View {
        if items.isEmpty {
            Text(empty).font(.callout).foregroundStyle(.secondary)
        } else {
            let top = items.map(\.seconds).max() ?? 1
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.name).lineLimit(1)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(DurationFormat.hoursMinutes(item.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        GeometryReader { geo in
                            Capsule().fill(Color.primary.opacity(0.07))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(color.gradient)
                                        .frame(width: max(4, geo.size.width * item.seconds / max(top, 1)))
                                }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }
}

private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

// MARK: - Sections

/// The headline numbers.
struct AnalyticsSummaryTiles: View {
    let snapshot: AnalyticsEngine.Snapshot
    let comparison: String

    var body: some View {
        let s = snapshot.summary
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.spacing), count: 4),
                  spacing: Theme.spacing) {
            MetricTile(title: "Tracked", value: DurationFormat.hoursMinutes(s.tracked.current),
                       systemImage: "clock", tint: .blue, delta: s.tracked, comparison: comparison)
            MetricTile(title: "Billable", value: "\(DurationFormat.hoursMinutes(s.billable.current)) · \(percent(s.billableShare.current))",
                       systemImage: "dollarsign.circle", tint: .green, delta: s.billable, comparison: comparison)
            MetricTile(title: "Per working day", value: DurationFormat.hoursMinutes(s.perWorkingDay.current),
                       systemImage: "calendar", tint: .purple, delta: s.perWorkingDay, comparison: comparison)
            MetricTile(title: "In meetings", value: DurationFormat.hoursMinutes(s.meetingSeconds.current),
                       systemImage: "person.2.wave.2", tint: .orange, delta: s.meetingSeconds,
                       comparison: comparison, higherIsGood: false)
            MetricTile(title: "Working days", value: "\(s.workingDays)", systemImage: "sun.max", tint: .yellow,
                       footnote: "days with 15 min or more")
            MetricTile(title: "Entries", value: "\(s.entryCount)", systemImage: "list.bullet", tint: .teal,
                       footnote: "average \(DurationFormat.hoursMinutes(s.averageEntry))")
            MetricTile(title: "No project", value: percent(snapshot.quality.unassignedShare),
                       systemImage: "folder.badge.questionmark", tint: .gray,
                       footnote: DurationFormat.hoursMinutes(snapshot.quality.unassignedSeconds))
            MetricTile(title: "Todos done", value: "\(snapshot.quality.todosCompleted)", systemImage: "checkmark.circle",
                       tint: .green, footnote: "completed in this period")
        }
    }
}

/// Hours per day, stacked by project.
struct DaysChartCard: View {
    let snapshot: AnalyticsEngine.Snapshot
    let colors: [String: Color]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Per day", systemImage: "chart.bar.xaxis")
                if snapshot.days.isEmpty {
                    Text("Nothing tracked in this period.").foregroundStyle(.secondary)
                } else {
                    Chart(snapshot.days) { slice in
                        BarMark(
                            x: .value("Day", slice.day, unit: .day),
                            y: .value("Hours", slice.seconds / 3600)
                        )
                        .foregroundStyle(colors[slice.key] ?? .gray)
                        .cornerRadius(3)
                    }
                    .chartXScale(domain: snapshot.interval.start...snapshot.interval.end)
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))h") } }
                        }
                    }
                    .frame(height: 200)
                    legend
                }
            }
        }
    }

    private var legend: some View {
        let names = Dictionary(snapshot.days.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        return FlowLayout(spacing: 6) {
            ForEach(names.sorted { $0.value < $1.value }, id: \.key) { key, name in
                Chip(text: name, color: colors[key] ?? .secondary)
            }
        }
    }
}

/// Donut plus a table by project, customer or role.
struct BreakdownCard: View {
    let snapshot: AnalyticsEngine.Snapshot
    let colors: [String: Color]
    let comparison: String
    @State private var dimension: AnalyticsEngine.Dimension = .project

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow, .indigo, .mint]

    private func color(_ line: AnalyticsEngine.BreakdownLine, _ index: Int) -> Color {
        if line.key == "none" { return .gray.opacity(0.6) }
        if dimension == .project { return colors[line.key] ?? .gray }
        return Self.palette[index % Self.palette.count]
    }

    var body: some View {
        let lines = snapshot.breakdown(by: dimension)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Breakdown", systemImage: "chart.pie") {
                    Picker("", selection: $dimension) {
                        ForEach(AnalyticsEngine.Dimension.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if lines.isEmpty {
                    Text("Nothing tracked in this period.").foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        Chart(Array(lines.enumerated()), id: \.element.id) { index, line in
                            SectorMark(angle: .value("Hours", line.seconds), innerRadius: .ratio(0.62), angularInset: 1.5)
                                .cornerRadius(3)
                                .foregroundStyle(color(line, index))
                        }
                        .chartBackground { _ in
                            Text(DurationFormat.hoursMinutes(snapshot.summary.tracked.current))
                                .font(.headline.monospacedDigit())
                        }
                        .frame(width: 180, height: 180)
                        table(lines)
                    }
                }
            }
        }
    }

    private func table(_ lines: [AnalyticsEngine.BreakdownLine]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text(dimension.rawValue)
                Text("Time").gridColumnAlignment(.trailing)
                Text("Share").gridColumnAlignment(.trailing)
                Text("Billable").gridColumnAlignment(.trailing)
                Text("vs \(comparison)").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Array(lines.prefix(10).enumerated()), id: \.element.id) { index, line in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(color(line, index)).frame(width: 8, height: 8)
                        Text(line.name).lineLimit(1)
                    }
                    Text(DurationFormat.hoursMinutes(line.seconds)).monospacedDigit()
                    Text(percent(line.share)).monospacedDigit().foregroundStyle(.secondary)
                    Text(line.billableSeconds > 0 ? percent(line.billableShare) : "—")
                        .monospacedDigit().foregroundStyle(line.billableSeconds > 0 ? .green : .secondary)
                    DeltaLabel(delta: .init(current: line.seconds, previous: line.previousSeconds),
                               comparison: "", compact: true)
                }
                .font(.callout)
            }
        }
    }
}

/// When the work happens: weekday × hour.
struct HeatmapCard: View {
    let snapshot: AnalyticsEngine.Snapshot
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let cells = Dictionary(snapshot.heatmap.map { ($0.id, $0.seconds) }, uniquingKeysWith: +)
        let hours = hourRange
        let peak = snapshot.heatmap.map(\.seconds).max() ?? 1
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("When you work", systemImage: "square.grid.3x3.fill") {
                    if let busiest = snapshot.heatmap.max(by: { $0.seconds < $1.seconds }) {
                        Text("Busiest: \(weekdays[busiest.weekday - 1]) \(busiest.hour):00")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if snapshot.heatmap.isEmpty {
                    Text("Nothing tracked in this period.").foregroundStyle(.secondary)
                } else {
                    Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                        GridRow {
                            Text("")
                            ForEach(hours, id: \.self) { h in
                                Text(h % 2 == 0 ? "\(h)" : "").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        ForEach(1...7, id: \.self) { day in
                            GridRow {
                                Text(weekdays[day - 1]).font(.caption).foregroundStyle(.secondary)
                                    .gridColumnAlignment(.leading)
                                ForEach(hours, id: \.self) { hour in
                                    let seconds = cells[day * 100 + hour] ?? 0
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(seconds > 0 ? Color.accentColor.opacity(0.15 + 0.85 * seconds / peak)
                                                          : Color.primary.opacity(0.05))
                                        .frame(height: 18)
                                        .help("\(weekdays[day - 1]) \(hour):00 · \(DurationFormat.hoursMinutes(seconds))")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 07–20 by default, widened to whatever hours have time in them.
    private var hourRange: [Int] {
        let used = snapshot.heatmap.map(\.hour)
        let low = min(used.min() ?? 7, 7), high = max(used.max() ?? 20, 20)
        return Array(low...high)
    }
}

/// Apps, sites and how scattered the time was.
struct FocusCard: View {
    let snapshot: AnalyticsEngine.Snapshot

    var body: some View {
        let f = snapshot.focus
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Apps, sites and focus", systemImage: "app.badge")
                if f.observedSeconds == 0 {
                    Text("No activity recorded in this period (activity is kept for 30 days).")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: Theme.spacing) {
                        stat("Communication", percent(f.communicationShare), "of the active time in chat, mail and calls")
                        stat("App switches", String(format: "%.0f / hour", f.switchesPerHour), "lower means more focused")
                        stat("Long blocks", "\(f.longBlocks)", "entries of 45 min or more · longest \(DurationFormat.hoursMinutes(f.longestBlock))")
                        stat("Away", DurationFormat.hoursMinutes(f.awaySeconds), "locked or idle during your working hours")
                    }
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top apps").font(.callout.weight(.semibold))
                            RankedBars(items: f.topApps, color: .indigo)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Top sites").font(.callout.weight(.semibold))
                            RankedBars(items: f.topSites, color: .teal, empty: "No browser activity.")
                        }
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Meetings: how many, how long, who talks.
struct MeetingsAnalyticsCard: View {
    let snapshot: AnalyticsEngine.Snapshot

    var body: some View {
        let m = snapshot.meetings
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Meetings", systemImage: "person.2.wave.2")
                if m.count == 0 {
                    Text("No meetings in this period.").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: Theme.spacing) {
                        stat("Meetings", "\(m.count)", "average \(DurationFormat.hoursMinutes(m.averageLength))")
                        stat("Time", DurationFormat.hoursMinutes(m.seconds), "\(percent(m.shareOfTracked)) of tracked time")
                        stat("You talked", m.myTalkShare.map(percent) ?? "—",
                             m.myTalkShare == nil ? "name your voice on a meeting's page" : "of the speech in recorded meetings")
                        stat("Proposed todos", "\(m.proposalsAccepted) ✓ · \(m.proposalsDeclined) ✕",
                             m.proposalsPending > 0 ? "\(m.proposalsPending) waiting" : "from meeting notes")
                    }
                    if let share = m.myTalkShare {
                        talkBar(share)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Time with each person").font(.callout.weight(.semibold))
                            RankedBars(items: m.people, color: .orange,
                                       empty: "Name the voices on a meeting's page to see who you spend time with.")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Longest meetings").font(.callout.weight(.semibold))
                            RankedBars(items: m.longest, color: .purple)
                        }
                    }
                }
            }
        }
    }

    private func talkBar(_ share: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(Color.accentColor.gradient).frame(width: max(4, geo.size.width * share))
                    Capsule().fill(Color.orange.gradient)
                }
            }
            .frame(height: 10)
            HStack {
                Text("You \(percent(share))").foregroundStyle(Color.accentColor)
                Spacer()
                Text("Others \(percent(1 - share))").foregroundStyle(.orange)
            }
            .font(.caption)
        }
    }

    private func stat(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How trustworthy the data is, and what Hansel did on its own.
struct QualityCard: View {
    let snapshot: AnalyticsEngine.Snapshot

    var body: some View {
        let q = snapshot.quality
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Data quality", systemImage: "checkmark.seal")
                HStack(spacing: Theme.spacing) {
                    gauge("Reviewed", q.reviewedShare, .green, "time you confirmed or entered")
                    gauge("Without project", q.unassignedShare, .orange, DurationFormat.hoursMinutes(q.unassignedSeconds))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switch questions").font(.caption).foregroundStyle(.secondary)
                        Text("\(q.questionsAsked)").font(.title3.weight(.semibold).monospacedDigit())
                        Text("\(q.questionsAccepted) switched · \(q.questionsRejected) same task · \(q.questionsIgnored) unanswered")
                            .font(.caption2).foregroundStyle(.tertiary)
                        if q.automaticSwitches > 0 {
                            Text("\(q.automaticSwitches) automatic (meetings joined)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("How entries started").font(.callout.weight(.semibold))
                    RankedBars(items: q.bySource, color: .blue)
                }
            }
        }
    }

    private func gauge(_ title: String, _ share: Double, _ color: Color, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(percent(share)).font(.title3.weight(.semibold).monospacedDigit())
            ProgressView(value: share).tint(color)
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays chips out in rows, wrapping as needed. A chip wider than a whole row is
/// offered the row's width, so its text truncates instead of overflowing the view.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: width)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private static func size(of view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        let fitted = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        return CGSize(width: min(fitted.width, maxWidth), height: fitted.height)
    }
}
