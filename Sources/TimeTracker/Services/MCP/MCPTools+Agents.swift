import Foundation
import SwiftData

/// Tools for an agent working on its own on todos the user delegated: take the next one,
/// report progress, ask, request approval for what the user must OK, and deliver.
extension MCPTools {

    func agentTools() -> [Tool] {
        let todoArg = Self.string("The todo's id, from next_delegated_task.")
        return [
            Tool(
                name: "delegate_todo", title: "Delegate todo",
                description: "Hands a todo to agents to work on in the background (delegate: true), or takes it back (false). Agents work on it when the user runs them from Hansel's Agents page, or when asked to work on delegated todos.",
                properties: ["todo": Self.string("The todo's id or title."),
                             "delegate": Self.boolean("true to delegate, false to take it back (default true).")],
                required: ["todo"], readOnly: false
            ) { [unowned self] args in
                let todo = try self.todo(try args.requiredString("todo"))
                if try args.bool("delegate") ?? true {
                    do { try DelegationService.delegate(todo, context: self.context) } catch let r as DelegationService.Rejection {
                        throw ToolError(r.message)
                    }
                } else {
                    DelegationService.undelegate(todo, context: self.context)
                }
                return ["todo": todo.breadcrumbPath, "state": todo.delegation.rawValue]
            },

            Tool(
                name: "next_delegated_task", title: "Next delegated task",
                description: """
                Takes the next todo the user delegated to agents and marks it as being worked on. Returns its \
                full context (brief, autonomy policy, dossier, time, sources) and `decisions`: the user's \
                answers, approvals, rejections and comments since the last turn. Do approved actions exactly \
                as approved; do not repeat rejected ones. Returns `task: null` when there is nothing to do.
                """,
                properties: [:], required: [], readOnly: false
            ) { [unowned self] _ in try nextDelegatedTask() },

            Tool(
                name: "log_progress", title: "Log progress",
                description: "Records what you did on a delegated todo, in one or two lines, with a link to any draft, page or file.",
                properties: ["todo": todoArg, "text": Self.string("What was done."),
                             "url": Self.string("Link to what was produced, if any.")],
                required: ["todo", "text"], readOnly: false
            ) { [unowned self] args in try record(.progress, args, titleKey: "text") },

            Tool(
                name: "ask_user", title: "Ask the user",
                description: "Asks the user something you cannot find out or decide yourself. The todo waits until they answer; carry on with any other work first.",
                properties: ["todo": todoArg, "question": Self.string("The question, answerable in a line."),
                             "context": Self.string("What you found and the options, briefly.")],
                required: ["todo", "question"], readOnly: false
            ) { [unowned self] args in try record(.question, args, titleKey: "question", bodyKey: "context") },

            Tool(
                name: "request_approval", title: "Request approval",
                description: """
                Asks the user to approve an action the autonomy policy or a (ask) brief step reserves for them: \
                sending a message or email, publishing, sharing customer data, touching production. Give the \
                exact action: recipients, channel or page, and the full text. Do not perform it now; once \
                approved it comes back in next_delegated_task's `decisions`.
                """,
                properties: ["todo": todoArg,
                             "action": Self.string("The action in a line, e.g. \"Send email to Ferran and Toni\"."),
                             "details": Self.string("Exactly what will be done: recipients, where, and the full text."),
                             "url": Self.string("Link to the draft, if there is one.")],
                required: ["todo", "action", "details"], readOnly: false
            ) { [unowned self] args in try record(.approval, args, titleKey: "action", bodyKey: "details") },

            Tool(
                name: "submit_deliverable", title: "Submit deliverable",
                description: "Hands the finished work to the user for review: what was produced, where it is, and how it meets the brief's \"Done when\".",
                properties: ["todo": todoArg, "title": Self.string("What was delivered."),
                             "summary": Self.string("How it meets the brief, and anything the user should check."),
                             "url": Self.string("Link to the deliverable.")],
                required: ["todo", "title", "summary"], readOnly: false
            ) { [unowned self] args in try record(.deliverable, args, titleKey: "title", bodyKey: "summary") },
        ]
    }

    private func nextDelegatedTask() throws -> JSONObject {
        guard let todo = DelegationService.takeNext(context: context) else { return ["task": NSNull()] }
        let decided = DelegationService.notes(for: todo, context: context)
            .filter { [.approved, .rejected, .answered, .sentBack].contains($0.status) }
        let decisions = decided.map { note -> JSONObject in
            ["kind": note.kind.rawValue, "decision": note.status.rawValue, "about": note.title,
             "details": note.body, "user_says": Self.value(note.answer), "url": Self.value(note.url)]
        }
        DelegationService.closeDecided(for: todo, context: context)
        var task = try taskContextJSON(for: todo)
        task["history"] = DelegationService.notes(for: todo, context: context).suffix(15).map { note -> JSONObject in
            ["kind": note.kind.rawValue, "title": note.title, "status": note.status.rawValue,
             "date": Self.format(note.createdAt)]
        }
        return ["task": task, "decisions": decisions]
    }

    private func record(_ kind: AgentNote.Kind, _ args: MCPArguments, titleKey: String, bodyKey: String? = nil) throws -> JSONObject {
        let todo = try self.todo(try args.requiredString("todo"))
        let title = try args.requiredString(titleKey)
        let body = try bodyKey.flatMap { try args.string($0) } ?? ""
        do {
            try DelegationService.record(kind, on: todo, title: title, body: body,
                                         url: try args.string("url").flatMap { $0.isEmpty ? nil : $0 }, context: context)
        } catch let rejection as DelegationService.Rejection {
            throw ToolError(rejection.message)
        }
        return ["saved": true, "todo": todo.breadcrumbPath, "state": todo.delegation.rawValue]
    }
}
