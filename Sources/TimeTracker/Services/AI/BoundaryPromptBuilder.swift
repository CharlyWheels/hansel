import Foundation

/// Builds the boundary-adjudication prompt.
///
/// The shape matters more than the wording. A flat chronological list — what the draft
/// prompt sends — is the wrong shape for "where did this change?", because it asks the
/// model to find a seam we have already located. Splitting the samples into explicit
/// BEFORE and AFTER blocks and stating the machine's own hypothesis turns an open
/// search into a yes/no judgement, which is both cheaper and far more reliable.
enum BoundaryPromptBuilder {

    static let systemPrompt = """
    You are a time-tracking assistant for a solution engineer. Local signals on the \
    user's Mac have proposed that the user switched tasks at a specific moment. Your job \
    is to judge whether that is correct and, if it is, name the new task.

    You respond with STRICT JSON only. No explanation outside the JSON block.

    JSON schema:
    {
      "same_task": true or false,
      "boundary_at": "ISO-8601 timestamp, or null when same_task is true",
      "title": "short action-oriented title for the NEW task, or null",
      "role": "exact role name from catalog or null",
      "project": "exact project name from catalog or null",
      "customer": "exact customer name from catalog or null",
      "todo": "short todo id (e.g. \\"T2\\") or null",
      "confidence": 0.0 to 1.0,
      "rationale": "one sentence"
    }

    Rules:
    - If the AFTER block is a brief interruption that returns to the BEFORE context \
    (checking chat, a quick search, a notification), answer same_task: true.
    - Answer same_task: false only when the user genuinely moved to different work.
    - NEVER invent a role, project, customer or todo that is not listed.
    - Set confidence honestly. Low confidence is useful; a confident guess is not.
    """

    static func build(context: BoundaryContext) -> (system: String, user: String) {
        var lines: [String] = []

        lines.append("Current time: \(iso.string(from: context.now))")

        if let entry = context.currentEntry {
            var summary = "Currently tracking: \"\(entry.title)\" since \(time.string(from: entry.startAt))"
            var parts: [String] = []
            if let r = entry.roleName { parts.append("role=\(r)") }
            if let p = entry.projectName { parts.append("project=\(p)") }
            if let c = entry.customerName { parts.append("customer=\(c)") }
            if let t = entry.todoTitle { parts.append("todo=\(t)") }
            if !parts.isEmpty { summary += " (\(parts.joined(separator: " ")))" }
            lines.append(summary)
        } else {
            lines.append("Nothing is currently being tracked.")
        }

        // State the hypothesis explicitly: the model adjudicates, it does not search.
        let reasonList = context.reasons.map(\.rawValue).joined(separator: ", ")
        lines.append(
            "\nLocal signals flagged a possible task boundary at \(time.string(from: context.boundaryAt)) "
            + "(score \(String(format: "%.2f", context.segmenterScore)); reasons: \(reasonList.isEmpty ? "none" : reasonList))."
        )

        lines.append("\n=== BEFORE (\(time.string(from: windowStart(context))) – \(time.string(from: context.boundaryAt))) ===")
        lines.append(contentsOf: sampleLines(context.before))
        lines.append("\n=== AFTER (\(time.string(from: context.boundaryAt)) – \(time.string(from: context.now))) ===")
        lines.append(contentsOf: sampleLines(context.after))

        let relevantIdle = context.idleSpans.filter { $0.end != nil }
        if !relevantIdle.isEmpty {
            lines.append("\nIdle / away periods:")
            for span in relevantIdle.prefix(10) {
                guard let end = span.end else { continue }
                let mins = Int(end.timeIntervalSince(span.start) / 60)
                lines.append("- \(time.string(from: span.start)) to \(time.string(from: end)) (\(mins) min)")
            }
        }

        if let meeting = context.meeting {
            var line = "\nCalendar: \"\(meeting.title)\" \(time.string(from: meeting.start))–\(time.string(from: meeting.end))"
            line += ", you \(meeting.attendance.rawValue.uppercased())"
            line += ", \(meeting.attendeeCount) attendee(s)"
            if meeting.hasConferenceURL { line += ", has video link" }
            if meeting.showsAsFree { line += ", shows as FREE (a hold, not necessarily a meeting)" }
            lines.append(line)
            lines.append("Microphone active in the AFTER block: \(context.meetingCorroborated ? "yes" : "no")")
        }

        if !context.ruleHints.isEmpty {
            lines.append("\nUser-defined rules matched — strong priors:")
            if let r = context.ruleHints.role { lines.append("- role: \(r.name)") }
            if let p = context.ruleHints.project { lines.append("- project: \(p.name)") }
            if let c = context.ruleHints.customer { lines.append("- customer: \(c.name)") }
        }

        lines.append("\nCatalog:")
        lines.append("Roles: \(context.roles.map { "\"\($0.name)\"" }.joined(separator: ", "))")
        lines.append("Projects: \(context.projects.map(describeProject).joined(separator: ", "))")
        lines.append("Customers: \(context.customers.map { "\"\($0.name)\"" }.joined(separator: ", "))")

        let todos = PromptBuilder.flattenTodos(roots: context.activeTodos)
        if !todos.isEmpty {
            lines.append("\nActive todos:")
            for item in todos {
                let indent = String(repeating: "  ", count: item.depth)
                lines.append("\(indent)- [\(item.key)] \(item.todo.breadcrumbPath)")
            }
        }

        if !context.recentEntries.isEmpty {
            lines.append("\nRecent entries the user confirmed (classification patterns):")
            for entry in context.recentEntries.prefix(25) {
                lines.append(
                    "- \"\(entry.title)\" role=\(entry.role?.name ?? "—") "
                    + "project=\(entry.project?.name ?? "—") customer=\(entry.customer?.name ?? "—")"
                )
            }
        }

        // Negative few-shots. Framed as before/after pairs and placed late, because
        // this teaches what NOT to trigger on — a different lesson from the catalog.
        if !context.corrections.isEmpty {
            lines.append("\nPast mistakes to avoid (your earlier suggestion → what the user actually wanted):")
            for correction in context.corrections.prefix(15) {
                let outcome: String
                if correction.accepted {
                    outcome = "user ACCEPTED"
                } else if let corrected = correction.correctedTitle {
                    outcome = "user corrected to: \"\(corrected)\""
                } else {
                    outcome = "user said: KEEP PREVIOUS TASK"
                }
                lines.append(
                    "- reason=\(correction.reason) evidence=\"\(correction.evidence)\" "
                    + "you said: \"\(correction.proposedTitle)\" → \(outcome)"
                )
            }
        }

        lines.append(
            "\n`boundary_at` MUST be between \(iso.string(from: context.earliestAllowed)) "
            + "and \(iso.string(from: context.latestAllowed))."
        )
        lines.append("\nRespond with only the JSON object.")
        return (systemPrompt, lines.joined(separator: "\n"))
    }

    private static func windowStart(_ context: BoundaryContext) -> Date {
        context.before.first?.timestamp ?? context.boundaryAt
    }

    private static func sampleLines(_ samples: [SignalSample]) -> [String] {
        guard !samples.isEmpty else { return ["(no activity recorded)"] }
        return samples.prefix(60).map { sample in
            var line = "- \(time.string(from: sample.timestamp)) \(sample.appName)"
            if let title = sample.windowTitle, !title.isEmpty { line += " — \(title)" }
            if let url = sample.url, !url.isEmpty { line += " [\(url)]" }
            if sample.flags.inCall { line += " (call signals active)" }
            return line
        }
    }

    private static func describeProject(_ project: Project) -> String {
        if let customer = project.customer {
            return "\"\(project.name)\" (customer: \(customer.name))"
        }
        return "\"\(project.name)\""
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
