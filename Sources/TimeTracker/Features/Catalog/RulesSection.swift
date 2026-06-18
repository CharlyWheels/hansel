import SwiftUI
import SwiftData

/// Reusable "Rules" section shown inside Role/Project/Customer detail views.
/// The parent owns the creation of new rules (it knows which entity the rule targets).
struct RulesSection: View {
    let rules: [ClassificationRule]
    let onAdd: () -> Void
    let onEdit: (ClassificationRule) -> Void
    let onDelete: (ClassificationRule) -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules").font(.headline)
                Spacer()
                Button {
                    onAdd()
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
            if rules.isEmpty {
                Text("No rules yet. Add a rule to give the AI deterministic hints about this item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(rules.sorted(by: { $0.priority > $1.priority })) { rule in
                    ruleRow(rule)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func ruleRow(_ rule: ClassificationRule) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { rule.isEnabled = $0; try? modelContext.save() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? "(unnamed)" : rule.name)
                        .font(.body.weight(.medium))
                    Text("priority \(rule.priority)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(rule.conditionsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                onEdit(rule)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                onDelete(rule)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .padding(.vertical, 4)
    }
}
