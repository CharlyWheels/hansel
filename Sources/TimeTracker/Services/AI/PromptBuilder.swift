import Foundation

/// Builds the `(system, user)` messages sent to an AI provider.
/// Honours the user's `ContextFieldSelection`: fields unchecked are omitted from the prompt.
enum PromptBuilder {
    static let systemPrompt = """
    You are a time-tracking assistant for a solution engineer. Given computer activity \
    and a catalog of roles, projects, and customers, you must draft a concise time-entry \
    title and pick the correct role, project, and customer. You respond with STRICT JSON \
    only. Do not include any explanation outside the JSON block.

    JSON schema:
    {
      "title": "short action-oriented entry title",
      "role": "exact role name from catalog or null",
      "project": "exact project name from catalog or null",
      "customer": "exact customer name from catalog or null",
      "rationale": "one-sentence reason"
    }

    If you are unsure, set the field to null. NEVER invent a name that is not in the catalog.
    """

    static func build(context: SuggestionContext) -> (system: String, user: String) {
        var lines: [String] = []

        lines.append("Time window: \(isoFormatter.string(from: context.windowStart)) to \(isoFormatter.string(from: context.windowEnd)) (\(Int(context.windowEnd.timeIntervalSince(context.windowStart) / 60)) min).")

        if context.fields.includeCalendarTitle, let title = context.calendarEventTitle, !title.isEmpty {
            lines.append("Calendar event title: \(title)")
        }

        if context.fields.includeTimeOfDay {
            lines.append("Time of day: \(DateFormatter.timeOnly.string(from: context.windowStart))")
        }
        if context.fields.includeDayOfWeek {
            lines.append("Day of week: \(DateFormatter.weekdayOnly.string(from: context.windowStart))")
        }

        if context.fields.includeAppSamples, !context.samples.isEmpty {
            lines.append("\nActivity samples (chronological):")
            for s in context.samples.prefix(120) {
                var line = "- \(DateFormatter.timeOnly.string(from: s.timestamp)) \(s.appName)"
                if let t = s.windowTitle, !t.isEmpty { line += " — \(t)" }
                if context.fields.includeBrowserURLs, let u = s.url, !u.isEmpty {
                    line += " [\(u)]"
                }
                lines.append(line)
            }
        }

        if context.fields.includeRecentEntries, !context.recentEntries.isEmpty {
            lines.append("\nRecent confirmed entries (for classification patterns):")
            for e in context.recentEntries.prefix(50) {
                let role = e.role?.name ?? "—"
                let project = e.project?.name ?? "—"
                let customer = e.customer?.name ?? "—"
                lines.append("- \"\(e.title)\" role=\(role) project=\(project) customer=\(customer)")
            }
        }

        if context.fields.includeCatalog {
            lines.append("\nCatalog:")
            let roleList = context.roles.map { "\"\($0.name)\"" }.joined(separator: ", ")
            let projectList = context.projects.map(describeProject).joined(separator: ", ")
            let customerList = context.customers.map { "\"\($0.name)\"" }.joined(separator: ", ")
            lines.append("Roles: \(roleList)")
            lines.append("Projects: \(projectList)")
            lines.append("Customers: \(customerList)")
        }

        if !context.ruleHints.isEmpty {
            lines.append("\nUser-defined rules matched — treat these as strong priors; only override with clear evidence from the activity samples:")
            if let r = context.ruleHints.role { lines.append("- role: \(r.name)") }
            if let p = context.ruleHints.project { lines.append("- project: \(p.name)") }
            if let c = context.ruleHints.customer { lines.append("- customer: \(c.name)") }
        }

        if !context.activeTodos.isEmpty {
            lines.append("\nActive todos (user-maintained task list — context only). Use this list to pick a more specific entry title or to recognize that the activity is a subtask of a larger todo. DO NOT add a todo field to your JSON output; the schema is unchanged.")
            var emitted = 0
            let cap = 40
            for root in context.activeTodos {
                appendTodoLines(root, depth: 0, into: &lines, emitted: &emitted, cap: cap)
                if emitted >= cap { break }
            }
        }

        lines.append("\nRespond with only the JSON object.")
        return (systemPrompt, lines.joined(separator: "\n"))
    }

    private static func appendTodoLines(
        _ todo: Todo,
        depth: Int,
        into lines: inout [String],
        emitted: inout Int,
        cap: Int
    ) {
        guard emitted < cap else { return }
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)- \(todo.title)"
        if let due = todo.dueAt {
            line += " (due \(todoDueFormatter.string(from: due))"
            if todo.dueStatus == .overdue { line += ", OVERDUE" }
            line += ")"
        }
        lines.append(line)
        emitted += 1
        for child in todo.orderedSubtasks where !child.isCompleted {
            if emitted >= cap { return }
            appendTodoLines(child, depth: depth + 1, into: &lines, emitted: &emitted, cap: cap)
        }
    }

    private static let todoDueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func describeProject(_ p: Project) -> String {
        if let customer = p.customer {
            return "\"\(p.name)\" (customer: \(customer.name))"
        } else {
            return "\"\(p.name)\""
        }
    }
}

private extension DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static let weekdayOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
}
