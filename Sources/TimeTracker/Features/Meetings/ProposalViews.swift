import SwiftUI
import SwiftData

/// One proposed todo with its filled-in context and the three answers.
struct ProposalRow: View {
    let proposal: TodoProposal
    let projects: [Project]
    let customers: [Customer]
    /// Hidden inside a meeting's own page, where it would only repeat the title.
    var showsMeeting: Bool = true
    var onOpenMeeting: ((UUID) -> Void)? = nil

    @Environment(ProposalService.self) private var service
    @State private var editing = false

    private var project: Project? { projects.first { $0.id == proposal.projectID } }
    private var customer: Customer? {
        customers.first { $0.id == proposal.customerID } ?? project?.customer
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: proposal.enrichment == .ai ? "sparkles" : "text.badge.plus")
                .foregroundStyle(.secondary)
                .help(proposal.enrichment == .ai ? "Refined by the model" : "Filled from your catalog")
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(proposal.likelyForSomeoneElse ? .secondary : .primary)
                chips
                if let hint = proposal.hint {
                    Label(hint, systemImage: proposal.likelyForSomeoneElse ? "person.crop.circle.badge.questionmark" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(proposal.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(proposal.evidence)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $editing) {
            ProposalEditorView(proposal: proposal, projects: projects, customers: customers)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let project {
                chip(project.name, systemImage: "folder", color: project.displayColor)
            } else {
                chip("No project", systemImage: "folder", color: .secondary)
            }
            if let customer { chip(customer.name, systemImage: "person.2", color: .secondary) }
            if let due = proposal.dueAt {
                chip(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar", color: .orange)
            }
            if showsMeeting {
                Button {
                    onOpenMeeting?(proposal.meetingID)
                } label: {
                    chip(meetingLabel, systemImage: "waveform", color: .secondary)
                }
                .buttonStyle(.plain)
                .disabled(onOpenMeeting == nil)
                .help("Open the meeting")
            } else if let t = proposal.timestampSeconds {
                chip(TranscriptGrouping.timestamp(t), systemImage: "clock", color: .secondary)
            }
        }
    }

    private var meetingLabel: String {
        let day = proposal.meetingStartedAt.formatted(.dateTime.day().month(.abbreviated))
        return "\(proposal.meetingTitle) · \(day)"
    }

    private func chip(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var actions: some View {
        switch proposal.status {
        case .pending:
            HStack(spacing: 4) {
                Button { service.decline(proposal) } label: { Image(systemName: "xmark") }
                    .help("Decline")
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .help("Edit before accepting")
                Button { service.accept(proposal) } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .help("Add to todos")
            }
            .controlSize(.small)
        case .accepted:
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .declined:
            HStack(spacing: 6) {
                Text("Declined").font(.caption).foregroundStyle(.secondary)
                Button("Restore") { service.restore(proposal) }
                    .controlSize(.small)
            }
        }
    }
}

/// Edits a proposal and accepts it in one go.
struct ProposalEditorView: View {
    let proposal: TodoProposal
    let projects: [Project]
    let customers: [Customer]

    @Environment(ProposalService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var projectID: UUID?
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title)
                    Picker("Project", selection: $projectID) {
                        Text("None").tag(UUID?.none)
                        ForEach(projects.sorted { $0.name < $1.name }) { p in
                            Text(p.customer.map { "\(p.name) — \($0.name)" } ?? p.name).tag(UUID?.some(p.id))
                        }
                    }
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Due", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    }
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .font(.callout)
                        .frame(minHeight: 140)
                }
                Section("Heard in \"\(proposal.meetingTitle)\"") {
                    Text(proposal.evidence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save(); dismiss() }
                Button("Add to todos") {
                    save()
                    service.accept(proposal)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            title = proposal.title
            notes = proposal.notes
            projectID = proposal.projectID
            hasDue = proposal.dueAt != nil
            due = proposal.dueAt ?? Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
        }
    }

    private func save() {
        proposal.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        proposal.notes = notes
        proposal.projectID = projectID
        // A project names its customer; keep the meeting's customer only without one.
        if let project = projects.first(where: { $0.id == projectID }), let customer = project.customer {
            proposal.customerID = customer.id
        }
        proposal.dueAt = hasDue ? due : nil
    }
}

/// The inbox at the top of Todos: everything heard in meetings and not yet decided.
struct ProposalInboxSection: View {
    @Query private var pending: [TodoProposal]
    @Query private var projects: [Project]
    @Query private var customers: [Customer]
    @Environment(MainWindowRouter.self) private var router
    @State private var expanded = true

    init() {
        _pending = Query(TodoProposal.pendingDescriptor)
    }

    var body: some View {
        if !pending.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pending) { proposal in
                        ProposalRow(proposal: proposal, projects: projects, customers: customers,
                                    onOpenMeeting: { router.openMeeting($0) })
                        if proposal.id != pending.last?.id { Divider() }
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Proposed from meetings (\(pending.count))", systemImage: "tray.and.arrow.down")
                    .font(.headline)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .bottom])
        }
    }
}
