import SwiftUI
import SwiftData

/// For the period: per customer, the time tracked against what happened (meetings,
/// threads, emails, pages); per todo, the same; and how well the collected context was
/// placed. A customer with plenty going on and no time tracked is worth a look.
struct ContextAnalyticsCard: View {
    let interval: DateInterval
    let entries: [TimeEntry]

    @Query private var items: [ContextItem]
    @Query private var todos: [Todo]
    @Query private var customers: [Customer]
    @Environment(MainWindowRouter.self) private var router

    var body: some View {
        let report = ContextInsights.report(items: items, todos: todos, customers: customers,
                                            entries: entries, interval: interval)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Customers, todos and context", systemImage: "tray.full") {
                    Button("Context") { router.selection = .context }.buttonStyle(.link).font(.caption)
                }
                if report.collected == 0 && report.customers.isEmpty {
                    Text("No context and no customer time in this period.").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: Theme.spacing) {
                        stat("Context collected", "\(report.collected)",
                             report.bySource.prefix(4).map { "\($0.count) \($0.source.label.lowercased())" }.joined(separator: " · "))
                        stat("Placed automatically", percent(report.placedAutomatically, of: report.collected - report.discarded),
                             "\(report.placedAutomatically) of \(max(0, report.collected - report.discarded)) kept")
                        stat("Placed by you", "\(report.corrected)", "from the inbox")
                        stat("Waiting", "\(report.waiting)", report.waiting > 0 ? "in the inbox" : "inbox empty")
                    }
                    if !report.customers.isEmpty {
                        customersTable(report.customers)
                    }
                    if !report.todos.isEmpty {
                        todosTable(Array(report.todos.prefix(8)))
                    }
                }
            }
        }
    }

    private func customersTable(_ lines: [ContextInsights.CustomerLine]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per customer: time tracked and what happened").font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Customer"); Text("Tracked"); Text("Context"); Text("Sources"); Text("Latest")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(lines) { line in
                    GridRow {
                        Button(line.name) { router.openContext(.customer(line.id)) }
                            .buttonStyle(.link)
                        Text(line.trackedSeconds > 0 ? DurationFormat.hoursMinutes(line.trackedSeconds) : "—")
                            .monospacedDigit()
                        HStack(spacing: 4) {
                            Text("\(line.items)").monospacedDigit()
                            if line.trackedSeconds == 0 && line.items >= 3 {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                    .help("A lot happened with this customer and no time was tracked for it.")
                            }
                        }
                        HStack(spacing: 8) {
                            ForEach(line.bySource.sorted { $0.value > $1.value }, id: \.key) { source, count in
                                Label("\(count)", systemImage: source.systemImage)
                                    .labelStyle(.titleAndIcon)
                                    .help(source.label)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(line.lastActivity?.formatted(.relative(presentation: .named)) ?? "—")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func todosTable(_ lines: [ContextInsights.TodoLine]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per open todo").font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Todo"); Text("Customer"); Text("Tracked"); Text("Context"); Text("Dossier")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(lines) { line in
                    GridRow {
                        Button(line.path) { router.openContext(.todo(line.id)) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        Text(line.customer ?? "—").foregroundStyle(.secondary)
                        Text(line.trackedSeconds > 0 ? DurationFormat.hoursMinutes(line.trackedSeconds) : "—")
                            .monospacedDigit()
                        Text("\(line.items)").monospacedDigit()
                        Text(line.dossierUpdatedAt.map { "updated " + $0.formatted(.relative(presentation: .named)) } ?? "none yet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ part: Int, of whole: Int) -> String {
        whole > 0 ? "\(Int((Double(part) / Double(whole) * 100).rounded()))%" : "—"
    }
}
