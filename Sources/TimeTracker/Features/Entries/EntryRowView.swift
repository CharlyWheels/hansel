import SwiftUI

/// Reusable single-entry row, used by both `EntryListView` and `DashboardView`.
struct EntryRowView: View {
    let entry: TimeEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                    .font(.body)
                HStack(spacing: 6) {
                    if let project = entry.project {
                        Text(project.name).font(.caption)
                    } else {
                        Text("No project").font(.caption).foregroundStyle(.secondary)
                    }
                    if let customer = entry.customer {
                        Text("· \(customer.name)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let role = entry.role {
                        Text("· \(role.name)").font(.caption).foregroundStyle(.secondary)
                    }
                    sourceBadge(entry.source)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let d = entry.duration {
                    Text(DurationFormat.hoursMinutes(d))
                        .monospacedDigit()
                }
                Text(entry.startAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var accentColor: Color {
        if let project = entry.project { return project.displayColor }
        return entry.billableCached ? Color.green : Color.gray.opacity(0.4)
    }

    private func sourceBadge(_ source: EntrySource) -> some View {
        let label: String
        switch source {
        case .manual: label = "manual"
        case .calendar: label = "calendar"
        case .aiAutoStart: label = "ai"
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
