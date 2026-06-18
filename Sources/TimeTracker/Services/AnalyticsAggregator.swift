import Foundation

enum Period: Hashable {
    case today
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case custom(from: Date, to: Date)

    /// Half-open interval [start, end) that the aggregator uses to filter entries.
    func interval(calendar: Calendar = .current, now: Date = Date()) -> DateInterval {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 0)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 0)
        case .lastWeek:
            let lastWeekDate = calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .weekOfYear, for: lastWeekDate) ?? DateInterval(start: now, duration: 0)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 0)
        case .lastMonth:
            let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .month, for: lastMonthDate) ?? DateInterval(start: now, duration: 0)
        case .custom(let from, let to):
            let start = min(from, to)
            let end = max(from, to)
            return DateInterval(start: start, end: end)
        }
    }

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .custom: return "Custom"
        }
    }
}

struct BreakdownRow: Identifiable, Hashable {
    let id: UUID
    let name: String
    let total: TimeInterval
    let billable: TimeInterval
    let share: Double   // fraction of grand total (0.0–1.0)
}

struct AnalyticsReport {
    let period: Period
    let interval: DateInterval
    let totalSeconds: TimeInterval
    let billableSeconds: TimeInterval
    let entryCount: Int
    let byCustomer: [BreakdownRow]
    let byProject: [BreakdownRow]
    let byRole: [BreakdownRow]
    let entries: [TimeEntry]
}

enum AnalyticsAggregator {
    /// Filters `entries` to the period interval and groups by customer/project/role.
    /// Entries with a `nil` dimension bucket into an "Unassigned" row.
    static func report(
        entries: [TimeEntry],
        period: Period,
        now: Date = Date()
    ) -> AnalyticsReport {
        let interval = period.interval(now: now)
        let filtered = entries.filter { entry in
            guard let end = entry.endAt else { return false }
            // Include an entry if it overlaps the interval at all.
            return end > interval.start && entry.startAt < interval.end
        }

        let total = filtered.reduce(0.0) { $0 + overlap(entry: $1, interval: interval) }
        let billable = filtered
            .filter { $0.billableCached }
            .reduce(0.0) { $0 + overlap(entry: $1, interval: interval) }

        return AnalyticsReport(
            period: period,
            interval: interval,
            totalSeconds: total,
            billableSeconds: billable,
            entryCount: filtered.count,
            byCustomer: breakdown(
                filtered,
                interval: interval,
                grandTotal: total,
                keyId: { $0.customer?.id },
                keyName: { $0.customer?.name ?? "Unassigned" }
            ),
            byProject: breakdown(
                filtered,
                interval: interval,
                grandTotal: total,
                keyId: { $0.project?.id },
                keyName: { $0.project?.name ?? "Unassigned" }
            ),
            byRole: breakdown(
                filtered,
                interval: interval,
                grandTotal: total,
                keyId: { $0.role?.id },
                keyName: { $0.role?.name ?? "Unassigned" }
            ),
            entries: filtered.sorted { $0.startAt < $1.startAt }
        )
    }

    // MARK: - Internals

    /// Seconds of the entry that fall within the interval.
    private static func overlap(entry: TimeEntry, interval: DateInterval) -> TimeInterval {
        guard let end = entry.endAt else { return 0 }
        let start = max(entry.startAt, interval.start)
        let stop = min(end, interval.end)
        return max(0, stop.timeIntervalSince(start))
    }

    private static func breakdown(
        _ entries: [TimeEntry],
        interval: DateInterval,
        grandTotal: TimeInterval,
        keyId: (TimeEntry) -> UUID?,
        keyName: (TimeEntry) -> String
    ) -> [BreakdownRow] {
        // One deterministic UUID for the "Unassigned" row so grouping is stable.
        let unassignedId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let grouped = Dictionary(grouping: entries) { entry in
            keyId(entry) ?? unassignedId
        }
        return grouped.map { (id, group) -> BreakdownRow in
            let name = group.first.map(keyName) ?? "Unassigned"
            let total = group.reduce(0.0) { $0 + overlap(entry: $1, interval: interval) }
            let billable = group
                .filter { $0.billableCached }
                .reduce(0.0) { $0 + overlap(entry: $1, interval: interval) }
            let share = grandTotal > 0 ? total / grandTotal : 0
            return BreakdownRow(id: id, name: name, total: total, billable: billable, share: share)
        }
        .sorted { $0.total > $1.total }
    }
}
