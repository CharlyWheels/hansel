import SwiftUI
import SwiftData

/// Shared editor sheet for both creating and editing a `ClassificationRule`.
/// The rule is expected to already be inserted into the `modelContext` — the view
/// auto-saves on changes, so "Done" is really just a dismiss button.
struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var rule: ClassificationRule

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name", text: $rule.name)
                Stepper("Priority: \(rule.priority)", value: $rule.priority, in: -100...100)
                Toggle("Enabled", isOn: $rule.isEnabled)
            }
            Section {
                optionalField(title: "App bundle ID", placeholder: "com.microsoft.powerbi.desktop",
                              keyPath: \ClassificationRule.appBundleID)
                optionalField(title: "App name contains", placeholder: "PowerBI",
                              keyPath: \ClassificationRule.appNameContains)
                optionalField(title: "URL contains", placeholder: "acme.com",
                              keyPath: \ClassificationRule.urlContains)
                optionalField(title: "Window title contains", placeholder: "Dashboard",
                              keyPath: \ClassificationRule.windowTitleContains)
                optionalField(title: "Calendar event title contains", placeholder: "standup",
                              keyPath: \ClassificationRule.calendarTitleContains)
            } header: {
                Text("Conditions")
            } footer: {
                Text("Leave a field blank to ignore it. Non-blank fields are AND-combined — all must match for the rule to fire.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                LabeledContent("Summary", value: rule.conditionsSummary)
                LabeledContent("Target", value: targetLabel)
                if !rule.hasAnyCondition {
                    Label("Rules without conditions never match — add at least one.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
        .onChange(of: rule.name)                   { _, _ in try? modelContext.save() }
        .onChange(of: rule.priority)               { _, _ in try? modelContext.save() }
        .onChange(of: rule.isEnabled)              { _, _ in try? modelContext.save() }
        .onChange(of: rule.appBundleID)            { _, _ in try? modelContext.save() }
        .onChange(of: rule.appNameContains)        { _, _ in try? modelContext.save() }
        .onChange(of: rule.urlContains)            { _, _ in try? modelContext.save() }
        .onChange(of: rule.windowTitleContains)    { _, _ in try? modelContext.save() }
        .onChange(of: rule.calendarTitleContains)  { _, _ in try? modelContext.save() }
    }

    private var targetLabel: String {
        if let r = rule.targetRole { return "Role → \(r.name)" }
        if let p = rule.targetProject { return "Project → \(p.name)" }
        if let c = rule.targetCustomer { return "Customer → \(c.name)" }
        return "—"
    }

    private func optionalField(
        title: String,
        placeholder: String,
        keyPath: ReferenceWritableKeyPath<ClassificationRule, String?>
    ) -> some View {
        TextField(
            title,
            text: Binding(
                get: { rule[keyPath: keyPath] ?? "" },
                set: { rule[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
            ),
            prompt: Text(placeholder)
        )
    }
}
