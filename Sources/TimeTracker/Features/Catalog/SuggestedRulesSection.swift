import SwiftUI
import SwiftData

/// "This site is almost always project X — add a rule?" from confirmed entries.
struct SuggestedRulesSection: View {
    @Environment(\.modelContext) private var modelContext
    let projects: [Project]

    @State private var suggestions: [RuleSuggester.Suggestion] = []
    private static let dismissedKey = "ruleSuggestions.dismissed"

    var body: some View {
        Group {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Suggested rules", systemImage: "wand.and.stars")
                        .font(.callout.weight(.medium))
                    Text("From entries you confirmed. A rule tells the AI which project this usually is.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(suggestions) { suggestion in
                        row(suggestion)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
        }
        .task { reload() }
    }

    private func row(_ s: RuleSuggester.Suggestion) -> some View {
        HStack(spacing: 8) {
            Text(s.condition.label).font(.callout.monospaced()).lineLimit(1)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(projectName(s.projectID)).font(.callout).lineLimit(1)
            Text("\(Int((s.share * 100).rounded()))% · \(s.entryCount) entries")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { dismiss(s) }.buttonStyle(.borderless)
            Button("Add rule") { add(s) }.buttonStyle(.bordered)
        }
    }

    private func projectName(_ id: UUID) -> String {
        projects.first { $0.id == id }?.name ?? "?"
    }

    private func reload() {
        let since = Date().addingTimeInterval(-60 * 86_400)
        let entryDescriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> {
                $0.isHumanConfirmed == true && $0.endAt != nil && $0.startAt >= since
            }
        )
        let entries = ((try? modelContext.fetch(entryDescriptor)) ?? []).filter { $0.project != nil }
        guard let earliest = entries.map(\.startAt).min() else { suggestions = []; return }
        let sampleDescriptor = FetchDescriptor<ActivitySample>(
            predicate: #Predicate<ActivitySample> { $0.timestamp >= earliest },
            sortBy: [SortDescriptor(\ActivitySample.timestamp)]
        )
        let samples = ((try? modelContext.fetch(sampleDescriptor)) ?? []).map {
            RuleSuggester.Point(timestamp: $0.timestamp, bundleId: $0.bundleId, appName: $0.appName, url: $0.url)
        }
        let rules = (try? modelContext.fetch(FetchDescriptor<ClassificationRule>())) ?? []
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        suggestions = Array(RuleSuggester.suggest(
            spans: entries.compactMap { e in
                guard let project = e.project, let end = e.endAt else { return nil }
                return RuleSuggester.Span(projectID: project.id, start: e.startAt, end: end)
            },
            samples: samples,
            existingURLFragments: rules.compactMap(\.urlContains),
            existingBundleIDs: Set(rules.compactMap(\.appBundleID)),
            dismissed: dismissed
        ).prefix(8))
    }

    private func add(_ s: RuleSuggester.Suggestion) {
        guard let project = projects.first(where: { $0.id == s.projectID }) else { return }
        let rule = ClassificationRule(name: "\(s.condition.label) → \(project.name)", targetProject: project)
        switch s.condition {
        case .host(let host): rule.urlContains = host
        case .app(let bundle, _): rule.appBundleID = bundle
        }
        modelContext.insert(rule)
        try? modelContext.save()
        suggestions.removeAll { $0.id == s.id }
    }

    private func dismiss(_ s: RuleSuggester.Suggestion) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        dismissed.append(s.id)
        UserDefaults.standard.set(dismissed, forKey: Self.dismissedKey)
        suggestions.removeAll { $0.id == s.id }
    }
}
