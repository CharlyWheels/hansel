import XCTest
@testable import TimeTracker

final class AnalyticsAggregatorTests: XCTestCase {

    // Fixed "now" — a Wednesday at 12:00 UTC so week/month ranges are predictable.
    private let now = ISO8601DateFormatter().date(from: "2026-04-22T12:00:00Z")!

    func test_empty_report_has_zero_totals() {
        let report = AnalyticsAggregator.report(entries: [], period: .thisWeek, now: now)
        XCTAssertEqual(report.totalSeconds, 0)
        XCTAssertEqual(report.billableSeconds, 0)
        XCTAssertTrue(report.byCustomer.isEmpty)
        XCTAssertTrue(report.byProject.isEmpty)
        XCTAssertTrue(report.byRole.isEmpty)
        XCTAssertEqual(report.entryCount, 0)
    }

    func test_two_customers_totals_and_shares() {
        let acme = Customer(name: "Acme")
        let beta = Customer(name: "Beta")
        let e1 = makeEntry(hoursAgo: 2, duration: 3600, customer: acme, billable: true)
        let e2 = makeEntry(hoursAgo: 5, duration: 3600, customer: acme, billable: true)
        let e3 = makeEntry(hoursAgo: 8, duration: 3600, customer: beta, billable: false)
        let report = AnalyticsAggregator.report(entries: [e1, e2, e3], period: .thisWeek, now: now)

        XCTAssertEqual(report.totalSeconds, 3 * 3600, accuracy: 1)
        XCTAssertEqual(report.billableSeconds, 2 * 3600, accuracy: 1)
        XCTAssertEqual(report.byCustomer.count, 2)
        let acmeRow = report.byCustomer.first { $0.name == "Acme" }!
        let betaRow = report.byCustomer.first { $0.name == "Beta" }!
        XCTAssertEqual(acmeRow.total, 2 * 3600, accuracy: 1)
        XCTAssertEqual(betaRow.total, 3600, accuracy: 1)
        XCTAssertEqual(acmeRow.share + betaRow.share, 1.0, accuracy: 0.001)
    }

    func test_billable_sum_excludes_non_billable() {
        let customer = Customer(name: "X")
        let billableEntry = makeEntry(hoursAgo: 1, duration: 1800, customer: customer, billable: true)
        let nonBillableEntry = makeEntry(hoursAgo: 3, duration: 1800, customer: customer, billable: false)
        let report = AnalyticsAggregator.report(
            entries: [billableEntry, nonBillableEntry], period: .thisWeek, now: now
        )
        XCTAssertEqual(report.totalSeconds, 3600, accuracy: 1)
        XCTAssertEqual(report.billableSeconds, 1800, accuracy: 1)
    }

    func test_nil_dimension_buckets_as_unassigned() {
        let e = makeEntry(hoursAgo: 1, duration: 1800, customer: nil, billable: false)
        let report = AnalyticsAggregator.report(entries: [e], period: .thisWeek, now: now)
        XCTAssertEqual(report.byCustomer.count, 1)
        XCTAssertEqual(report.byCustomer.first?.name, "Unassigned")
    }

    func test_entries_outside_period_are_excluded() {
        let customer = Customer(name: "X")
        // 40 days ago → outside thisWeek and thisMonth
        let oldEntry = makeEntry(hoursAgo: 40 * 24, duration: 3600, customer: customer, billable: true)
        let recent = makeEntry(hoursAgo: 2, duration: 3600, customer: customer, billable: true)
        let report = AnalyticsAggregator.report(entries: [oldEntry, recent], period: .thisWeek, now: now)
        XCTAssertEqual(report.entryCount, 1)
        XCTAssertEqual(report.totalSeconds, 3600, accuracy: 1)
    }

    // MARK: - Helpers

    private func makeEntry(
        hoursAgo: Double,
        duration: TimeInterval,
        customer: Customer?,
        billable: Bool
    ) -> TimeEntry {
        let start = now.addingTimeInterval(-hoursAgo * 3600)
        let end = start.addingTimeInterval(duration)
        let project = customer.map { Project(name: "P", customer: $0, defaultBillable: billable) }
        let role = Role(name: "R", defaultBillable: billable)
        return TimeEntry(
            title: "entry",
            startAt: start,
            endAt: end,
            role: role,
            project: project,
            customer: customer,
            isConfirmed: true,
            billableCached: billable
        )
    }
}
