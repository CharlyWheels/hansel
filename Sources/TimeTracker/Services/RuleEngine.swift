import Foundation

/// Pure evaluator that turns a set of user-defined rules into partial classification
/// hints. First match per field wins (rules sorted by `priority` descending). Rules with
/// no conditions never match.
enum RuleEngine {
    struct Hints: Equatable {
        var role: Role?
        var project: Project?
        var customer: Customer?
        var isEmpty: Bool { role == nil && project == nil && customer == nil }
    }

    static func evaluate(
        rules: [ClassificationRule],
        samples: [ActivitySample],
        calendarEventTitle: String? = nil
    ) -> Hints {
        let ordered = rules
            .filter { $0.isEnabled && $0.hasAnyCondition }
            .sorted { $0.priority > $1.priority }

        var hints = Hints()
        for rule in ordered {
            guard matches(rule: rule, samples: samples, calendarEventTitle: calendarEventTitle) else {
                continue
            }
            if hints.role == nil, let r = rule.targetRole { hints.role = r }
            if hints.project == nil, let p = rule.targetProject { hints.project = p }
            if hints.customer == nil, let c = rule.targetCustomer { hints.customer = c }
            if hints.role != nil && hints.project != nil && hints.customer != nil { break }
        }
        return hints
    }

    /// All non-nil conditions must be satisfied (AND). For sample-level conditions,
    /// "any sample in the window" is sufficient.
    static func matches(
        rule: ClassificationRule,
        samples: [ActivitySample],
        calendarEventTitle: String?
    ) -> Bool {
        var checks: [Bool] = []

        if let bundle = nonEmpty(rule.appBundleID) {
            let target = bundle.lowercased()
            checks.append(samples.contains { $0.bundleId.lowercased() == target })
        }
        if let appName = nonEmpty(rule.appNameContains) {
            let target = appName.lowercased()
            checks.append(samples.contains { $0.appName.lowercased().contains(target) })
        }
        if let url = nonEmpty(rule.urlContains) {
            let target = url.lowercased()
            checks.append(samples.contains { ($0.url ?? "").lowercased().contains(target) })
        }
        if let wt = nonEmpty(rule.windowTitleContains) {
            let target = wt.lowercased()
            checks.append(samples.contains { ($0.windowTitle ?? "").lowercased().contains(target) })
        }
        if let ct = nonEmpty(rule.calendarTitleContains) {
            let target = ct.lowercased()
            let haystack = (calendarEventTitle ?? "").lowercased()
            checks.append(haystack.contains(target))
        }

        return !checks.isEmpty && checks.allSatisfy { $0 }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
