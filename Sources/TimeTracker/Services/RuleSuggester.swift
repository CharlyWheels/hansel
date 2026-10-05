import Foundation

/// Proposes classification rules from what the user already confirmed: a website or
/// app that almost always means one project becomes a one-click rule.
///
/// Pure and value-typed so the thresholds are unit-testable.
enum RuleSuggester {

    struct Span: Equatable {
        let projectID: UUID
        let start: Date
        let end: Date
    }

    struct Point: Equatable {
        let timestamp: Date
        let bundleId: String
        let appName: String
        let url: String?
    }

    enum Condition: Hashable {
        case host(String)
        case app(bundleId: String, name: String)

        var key: String {
            switch self {
            case .host(let h): return "host:\(h)"
            case .app(let b, _): return "app:\(b)"
            }
        }

        var label: String {
            switch self {
            case .host(let h): return h
            case .app(_, let name): return name
            }
        }
    }

    struct Suggestion: Identifiable, Equatable {
        let condition: Condition
        let projectID: UUID
        /// Share of this condition's tracked time that went to the project.
        let share: Double
        let entryCount: Int
        let seconds: TimeInterval
        var id: String { "\(condition.key)>\(projectID.uuidString)" }
    }

    /// Apps used for everything; on their own they say nothing about the project.
    static let genericApps: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.apple.finder", "com.tinyspeck.slackmacgap", "com.microsoft.teams2",
        "com.microsoft.teams", "com.microsoft.Outlook", "com.apple.mail",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.Preview",
        "com.openai.chat", "com.anthropic.claudefordesktop", "com.apple.Notes",
    ]

    /// Seconds a single sample stands for (the activity monitor samples every 30 s).
    static let secondsPerSample: TimeInterval = 30

    static func suggest(
        spans: [Span],
        samples: [Point],
        existingURLFragments: [String],
        existingBundleIDs: Set<String>,
        dismissed: Set<String> = [],
        minShare: Double = 0.7,
        minEntries: Int = 3,
        minSeconds: TimeInterval = 1800
    ) -> [Suggestion] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var seconds: [Condition: [UUID: TimeInterval]] = [:]
        var entries: [Condition: [UUID: Int]] = [:]

        for span in spans {
            var seenInSpan: Set<Condition> = []
            for point in sorted where point.timestamp >= span.start && point.timestamp < span.end {
                for condition in conditions(for: point) {
                    seconds[condition, default: [:]][span.projectID, default: 0] += secondsPerSample
                    if seenInSpan.insert(condition).inserted {
                        entries[condition, default: [:]][span.projectID, default: 0] += 1
                    }
                }
            }
        }

        let fragments = existingURLFragments.map { $0.lowercased() }.filter { !$0.isEmpty }
        var out: [Suggestion] = []
        for (condition, byProject) in seconds {
            let total = byProject.values.reduce(0, +)
            guard let (projectID, top) = byProject.max(by: { $0.value < $1.value }), total > 0 else { continue }
            let share = top / total
            let count = entries[condition]?[projectID] ?? 0
            guard share >= minShare, count >= minEntries, top >= minSeconds else { continue }
            if isCovered(condition, fragments: fragments, bundleIDs: existingBundleIDs) { continue }
            let suggestion = Suggestion(condition: condition, projectID: projectID,
                                        share: share, entryCount: count, seconds: top)
            if dismissed.contains(suggestion.id) { continue }
            out.append(suggestion)
        }
        return out.sorted { $0.seconds > $1.seconds }
    }

    private static func conditions(for point: Point) -> [Condition] {
        var out: [Condition] = []
        if let host = TitleTokenizer.hostKey(from: point.url) { out.append(.host(host)) }
        if !genericApps.contains(point.bundleId) && !ActivityMonitor.isIgnored(point.bundleId) {
            out.append(.app(bundleId: point.bundleId, name: point.appName))
        }
        return out
    }

    private static func isCovered(_ condition: Condition, fragments: [String], bundleIDs: Set<String>) -> Bool {
        switch condition {
        case .host(let host):
            return fragments.contains { host.contains($0) || $0.contains(host) }
        case .app(let bundle, _):
            return bundleIDs.contains(bundle)
        }
    }
}
