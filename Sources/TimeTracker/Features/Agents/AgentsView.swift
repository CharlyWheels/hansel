import SwiftUI
import SwiftData

/// The todos handed to agents: what needs the user (questions, actions to approve),
/// what is ready for review, what is queued or in progress, and what the agents did.
/// Agents only run when the user presses "Run agents now".
struct AgentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ContextRunner.self) private var runner
    @Environment(MainWindowRouter.self) private var router

    @Query(sort: [SortDescriptor(\AgentNote.createdAt, order: .reverse)]) private var notes: [AgentNote]
    @AppStorage(ContextRunner.autoRunKey) private var autoRun = true
    @Query(sort: [SortDescriptor(\Todo.sortOrder)]) private var todos: [Todo]

    private var delegated: [Todo] {
        todos.filter { $0.delegation != .none }
            .sorted { ($0.delegatedAt ?? .distantPast) < ($1.delegatedAt ?? .distantPast) }
    }
    private var needsYou: [AgentNote] { notes.filter { $0.needsUser && $0.kind != .deliverable } }
    private var toReview: [AgentNote] { notes.filter { $0.needsUser && $0.kind == .deliverable } }
    private var queuedCount: Int { delegated.filter { $0.delegation == .queued }.count }

    private func todo(_ id: UUID) -> Todo? { todos.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            RunnerBanner()
            Form {
                Section {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Agents").font(.title2.weight(.semibold))
                            Text("\(delegated.count) delegated · \(queuedCount) queued · \(needsYou.count) need you · \(toReview.count) to review")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            runner.runAgents()
                        } label: {
                            Label("Run agents now", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(runner.isRunning || queuedCount == 0)
                        .help(queuedCount == 0
                              ? "Nothing is queued. Delegate a todo, or answer what the agents asked."
                              : "Codex works through the queued todos. It only drafts and asks: nothing is sent without your approval here.")
                    }
                    Toggle("Start agents on their own when you delegate a todo or answer them", isOn: $autoRun)
                } footer: {
                    Text("Agents work read-only and never send: emails are left in your Outlook Drafts, and they ask before anything else the policy reserves for you. Each run takes up to three todos and carries on while there is queued work.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !needsYou.isEmpty {
                    Section("Needs you (\(needsYou.count))") {
                        ForEach(needsYou) { note in
                            DecisionRow(note: note, todo: todo(note.todoID))
                        }
                    }
                }
                if !toReview.isEmpty {
                    Section("Ready for review (\(toReview.count))") {
                        ForEach(toReview) { note in
                            DecisionRow(note: note, todo: todo(note.todoID))
                        }
                    }
                }
                Section("Delegated todos") {
                    if delegated.isEmpty {
                        Text("Nothing delegated. Use \"Delegate to agents\" on a todo, or ask Codex to delegate it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(delegated) { todo in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Button(todo.breadcrumbPath) { router.openContext(.todo(todo.id)) }
                                    .buttonStyle(.link)
                                HStack(spacing: 6) {
                                    DelegationChip(state: todo.delegation)
                                    if let progress = briefProgress(todo) {
                                        Text(progress).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("No brief yet").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            Spacer()
                            Button("Take back") { DelegationService.undelegate(todo, context: modelContext) }
                                .controlSize(.small)
                        }
                    }
                }
                let activity = Array(notes.prefix(30))
                if !activity.isEmpty {
                    Section("Activity") {
                        ForEach(activity) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: Self.icon(note.kind)).foregroundStyle(.secondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.title).lineLimit(2)
                                    Text(todo(note.todoID)?.title ?? "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let link = note.url.flatMap(URL.init(string:)) {
                                    Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                                }
                                Text(note.createdAt.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Agents")
    }

    static func icon(_ kind: AgentNote.Kind) -> String {
        switch kind {
        case .progress: return "checkmark.circle"
        case .question: return "questionmark.bubble"
        case .approval: return "hand.raised"
        case .deliverable: return "shippingbox"
        }
    }
}

/// One question, approval or deliverable waiting for the user, with its answer controls.
private struct DecisionRow: View {
    let note: AgentNote
    let todo: Todo?

    @Environment(\.modelContext) private var modelContext
    @State private var text = ""
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: AgentsView.icon(note.kind)).foregroundStyle(.orange).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).font(.body.weight(.medium))
                    Text(todo?.breadcrumbPath ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let link = note.url.flatMap(URL.init(string:)) {
                    Link(destination: link) { Label("Open", systemImage: "arrow.up.right.square") }
                }
                Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.borderless)
            }
            if expanded, !note.body.isEmpty {
                Text(DossierSection.inline(note.body))
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            switch note.kind {
            case .approval:
                HStack {
                    TextField("Comment or reason (optional)", text: $text)
                    Button("Reject") { DelegationService.reject(note, reason: text, context: modelContext) }
                    Button("Approve") { DelegationService.approve(note, comment: text, context: modelContext) }
                        .buttonStyle(.borderedProminent)
                }
            case .question:
                HStack {
                    TextField("Your answer", text: $text).onSubmit(send)
                    Button("Answer", action: send).buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .deliverable:
                HStack {
                    TextField("What to change, to send it back", text: $text)
                    Button("Send back") { DelegationService.sendBack(note, comment: text, context: modelContext) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Accept and complete") { DelegationService.accept(note, context: modelContext) }
                        .buttonStyle(.borderedProminent)
                }
            case .progress:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        DelegationService.answer(note, text, context: modelContext)
    }
}

struct DelegationChip: View {
    let state: Delegation

    var body: some View {
        Chip(text: state.label, systemImage: icon, color: color)
    }

    private var icon: String {
        switch state {
        case .none: return "person"
        case .queued: return "clock"
        case .working: return "gearshape.2"
        case .waiting: return "hand.raised"
        case .review: return "shippingbox"
        }
    }

    private var color: Color {
        switch state {
        case .waiting, .review: return .orange
        case .working: return .blue
        default: return .secondary
        }
    }
}

/// Hands a todo to the agents, or takes it back.
struct DelegateButton: View {
    let todo: Todo
    @Environment(\.modelContext) private var modelContext
    @State private var error: String?

    var body: some View {
        HStack(spacing: 6) {
            if todo.delegation == .none {
                Button {
                    do { try DelegationService.delegate(todo, context: modelContext) } catch let r as DelegationService.Rejection {
                        error = r.message
                    } catch {}
                } label: {
                    Label("Delegate to agents", systemImage: "person.2.badge.gearshape")
                }
                .disabled(todo.isExcludedFromContext || todo.isCompleted)
                .help("Agents work on it when you press Run agents now on the Agents page.")
            } else {
                DelegationChip(state: todo.delegation)
                Button("Take back") { DelegationService.undelegate(todo, context: modelContext) }
                    .buttonStyle(.link)
            }
        }
        .alert("Cannot delegate", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
