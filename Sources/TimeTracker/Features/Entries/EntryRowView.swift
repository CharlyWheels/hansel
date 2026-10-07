import SwiftUI

/// One time entry in a list: its colour, title, labels and time.
struct EntryRowView: View {
    let entry: TimeEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(entry.displayColor.gradient)
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if entry.needsReview {
                        // Unreviewed entries are not used as examples for the model.
                        Image(systemName: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Not reviewed. Mark it as correct so the model learns from it.")
                    }
                }
                HStack(spacing: 6) {
                    if let project = entry.project {
                        Chip(text: project.name, systemImage: "folder", color: project.displayColor)
                    } else {
                        Chip(text: "No project", systemImage: "folder")
                    }
                    if let customer = entry.customer {
                        Chip(text: customer.name, systemImage: "person.2")
                    }
                    if let role = entry.role {
                        Chip(text: role.name, systemImage: "person")
                    }
                    sourceChip
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let d = entry.duration {
                    Text(DurationFormat.hoursMinutes(d))
                        .font(.body.weight(.medium).monospacedDigit())
                }
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if entry.billableCached {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.green)
                    .help("Billable")
            }
        }
        .padding(.vertical, 4)
    }

    private var timeRange: String {
        let start = entry.startAt.formatted(date: .omitted, time: .shortened)
        guard let end = entry.endAt else { return start }
        return "\(start)–\(end.formatted(date: .omitted, time: .shortened))"
    }

    /// Where the entry came from, as a small icon chip.
    private var sourceChip: some View {
        let (label, icon): (String, String) = {
            switch entry.source {
            case .manual: return ("Manual", "hand.tap")
            case .calendar: return ("Calendar", "calendar")
            case .aiAutoStart: return ("AI", "sparkles")
            case .aiSwitch: return ("AI switch", "arrow.triangle.branch")
            case .userCorrected: return ("Corrected", "pencil")
            }
        }()
        return Chip(text: label, systemImage: icon)
    }
}
