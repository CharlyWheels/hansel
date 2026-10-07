import SwiftUI
import SwiftData

/// The menu bar popover, built around today: the day as a strip of coloured blocks and
/// its totals, the task in progress as a card, any question waiting as a card, and the
/// todos, proposals and recent entries in tabs.
///
/// It keeps one size. When its content changed height (adding a todo, a banner
/// appearing) the MenuBarExtra window resized while focused and was left as a black
/// rectangle until reopened, so everything between the header and the footer scrolls
/// in a fixed-height area.
struct MenuBarContent: View {
    @Environment(TimerController.self) private var controller
    @Environment(EntryCompletionService.self) private var completion
    @Environment(FocusPromptCenter.self) private var prompts
    @Environment(ProposalService.self) private var proposalService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(MainWindowRouter.self) private var router
    @Query(TodoProposal.pendingDescriptor) private var pendingProposals: [TodoProposal]

    @Query(sort: [SortDescriptor(\Project.name)]) private var projects: [Project]
    @Query(sort: [SortDescriptor(\Role.name)]) private var roles: [Role]
    /// Only the few shown, not every closed entry ever recorded.
    @Query(MenuBarContent.recentDescriptor) private var recentEntries: [TimeEntry]
    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]

    @State private var newTodoTitle: String = ""
    @State private var tab: Tab = .todos
    @FocusState private var titleFocused: Bool
    @FocusState private var quickAddFocused: Bool

    static let width: CGFloat = 380
    static let scrollHeight: CGFloat = 470

    enum Tab: Hashable { case todos, proposed, recent }

    private static var recentDescriptor: FetchDescriptor<TimeEntry> {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endAt != nil },
            sortBy: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
        )
        descriptor.fetchLimit = 8
        return descriptor
    }

    private var activeTodos: [Todo] { allTodos.filter { !$0.isCompleted } }
    private var activeRootTodos: [Todo] { activeTodos.filter { $0.parent == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            todayHeader
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    PermissionBanner()
                    notices
                    taskCard
                    tabs
                }
                .padding(14)
            }
            .frame(height: Self.scrollHeight)
            Divider()
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: Self.width)
    }

    // MARK: - Today

    private var todayHeader: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = TodaySummary.load(context: modelContext, now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    HanselLogoView(size: 18)
                    Text("Today")
                        .font(.headline)
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(DurationFormat.hoursMinutes(today.strip.trackedSeconds))
                        .font(.headline.monospacedDigit())
                }
                DayStrip(model: today.strip) { key in today.colors[key] ?? .gray }
                HStack(spacing: 10) {
                    Label("\(today.entryCount) entr\(today.entryCount == 1 ? "y" : "ies")", systemImage: "list.bullet")
                    Label("\(today.billablePercent)% billable", systemImage: "dollarsign.circle")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let pending = prompts.pending { switchCard(pending) }
        if let undo = prompts.undoable { undoCard(undo) }
        if let prompt = completion.pendingPrompt { completionCard(prompt) }
        if let notice = completion.awayNotice { awayCard(notice) }
    }

    /// Three answers, not two. "Switch" and "something else" mean different things: the
    /// first says the boundary AND the label were right, the second says only the
    /// boundary was. Collapsing them would record a wrong label as an accepted proposal
    /// and teach the model its own mistake.
    private func switchCard(_ pending: FocusPromptCenter.PendingSwitch) -> some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Still on \"\(pending.previousTitle)\"?")
                            .font(.callout.weight(.semibold))
                        if pending.hasLabel {
                            Text("Looks like you're now on \"\(pending.proposedTitle)\".").font(.callout)
                        } else {
                            Text("Something changed at \(hhmm(pending.proposal.boundaryAt)), but I can't tell what.")
                                .font(.callout)
                        }
                        // Showing the evidence is what makes the question make sense.
                        Text(pending.proposal.evidence)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                }
                HStack(spacing: 6) {
                    Button("Same task") { prompts.keepCurrent() }
                    Spacer()
                    Button("Something else…") {
                        prompts.switchAndEdit()
                        openMainWindow()
                    }
                    if pending.hasLabel {
                        Button("Switch") { prompts.applySwitch() }.buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func undoCard(_ undo: FocusPromptCenter.UndoRecord) -> some View {
        Card(tint: .blue, padding: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.blue)
                Text("Switched to \"\(undo.title)\"").font(.callout).lineLimit(1)
                Spacer()
                Button("Undo") { prompts.undoLastSwitch() }.controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func completionCard(_ prompt: EntryCompletionService.PendingPrompt) -> some View {
        switch prompt.kind {
        case .doneQuestion:
            Card(tint: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(prompt.message, systemImage: "questionmark.circle.fill")
                        .font(.callout)
                        .lineLimit(3)
                    HStack {
                        Button("End entry", role: .destructive) { completion.confirmEnd() }
                        Spacer()
                        Button("Keep going") { completion.confirmContinue() }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func awayCard(_ notice: EntryCompletionService.AwayNotice) -> some View {
        Card(tint: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.message).font(.callout).lineLimit(3)
                        Text("Away \(hhmm(notice.from))–\(hhmm(notice.to)). Time away from the Mac isn't tracked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(.blue)
                }
                HStack(spacing: 6) {
                    if completion.canKeepAwayTime {
                        Button("Keep that time") { completion.keepAwayTime() }
                    }
                    Spacer()
                    Button("OK") { completion.dismissAwayNotice() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Current task

    @ViewBuilder
    private var taskCard: some View {
        if let entry = controller.runningEntry {
            runningCard(entry)
        } else {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing running").font(.callout.weight(.semibold))
                        Text("Hansel starts one for a meeting or after 10 min of activity.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { controller.startManual() } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(";", modifiers: [.command])
                }
            }
        }
    }

    private func runningCard(_ entry: TimeEntry) -> some View {
        @Bindable var entry = entry
        return Card(tint: entry.project?.displayColor ?? .accentColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    TextField("What are you working on?", text: $entry.title)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.semibold))
                        .focused($titleFocused)
                        // Only typing counts as a human edit. The title also changes when
                        // a switch replaces the running entry, and treating that as the
                        // user vouching for it fed the model's own guess back.
                        .onChange(of: entry.title) { _, _ in
                            if titleFocused { saveEntry() }
                        }
                }
                HStack(spacing: 6) {
                    Menu {
                        Button("No project") { setProject(nil, on: entry) }
                        ForEach(projects) { project in
                            Button(project.customer.map { "\(project.name) — \($0.name)" } ?? project.name) {
                                setProject(project, on: entry)
                            }
                        }
                    } label: {
                        Chip(text: entry.project?.name ?? "No project", systemImage: "folder",
                             color: entry.project?.displayColor ?? .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Menu {
                        Button("No role") { entry.role = nil; entry.refreshBillableCache(); saveEntry() }
                        ForEach(roles) { role in
                            Button(role.name) { entry.role = role; entry.refreshBillableCache(); saveEntry() }
                        }
                    } label: {
                        Chip(text: entry.role?.name ?? "Role", systemImage: "person")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Menu {
                        Button("No todo") { entry.linkedTodo = nil; saveEntry() }
                        ForEach(activeTodos) { todo in
                            Button(todo.breadcrumbPath) { entry.linkedTodo = todo; saveEntry() }
                        }
                    } label: {
                        Chip(text: entry.linkedTodo?.title ?? "Todo", systemImage: "checklist",
                             color: entry.linkedTodo?.inheritedDisplayColor ?? .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                HStack(alignment: .lastTextBaseline) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(DurationFormat.clock(controller.elapsed))
                            .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if let customer = entry.customer {
                            Text(customer.name).font(.caption).foregroundStyle(.secondary)
                        }
                        billableLabel(entry)
                    }
                    Spacer()
                    Button(role: .destructive) { controller.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut("s", modifiers: [.command])
                }
            }
        }
    }

    private func setProject(_ project: Project?, on entry: TimeEntry) {
        entry.project = project
        if entry.customer == nil { entry.customer = project?.customer }
        entry.refreshBillableCache()
        saveEntry()
    }

    /// Called whenever the user edits the running entry. Touching it by hand promotes an
    /// auto-started entry to a trustworthy classification example, and buys it
    /// protection: the arbiter will not propose over a recent human decision.
    private func saveEntry() {
        controller.runningEntry?.isHumanConfirmed = true
        controller.noteManualEdit()
        try? modelContext.save()
    }

    private func billableLabel(_ entry: TimeEntry) -> some View {
        let billable = BillableResolver.resolve(role: entry.role, project: entry.project, customer: entry.customer)
        return Label(billable ? "Billable" : "Non-billable",
                     systemImage: billable ? "dollarsign.circle.fill" : "dollarsign.circle")
            .font(.caption)
            .foregroundStyle(billable ? .green : .secondary)
    }

    // MARK: - Tabs

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("Todos").tag(Tab.todos)
                Text(pendingProposals.isEmpty ? "Proposed" : "Proposed (\(pendingProposals.count))").tag(Tab.proposed)
                Text("Recent").tag(Tab.recent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .todos: todosList
            case .proposed: proposedList
            case .recent: recentList
            }
        }
    }

    private var todosList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                TextField("Add a todo…", text: $newTodoTitle)
                    .textFieldStyle(.plain)
                    .focused($quickAddFocused)
                    .onSubmit(addTodo)
                if !newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add", action: addTodo).controlSize(.small)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(.background.secondary))
            if activeRootTodos.isEmpty {
                emptyRow("No open todos", systemImage: "checkmark.circle")
            } else {
                ForEach(activeRootTodos.prefix(8)) { todo in
                    HStack(spacing: 8) {
                        Button {
                            todo.isCompleted = true
                            todo.completedAt = Date()
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Mark done")
                        Text(todo.title.isEmpty ? "(untitled)" : todo.title)
                            .lineLimit(1)
                            .foregroundStyle(todo.inheritedDisplayColor ?? .primary)
                        Spacer()
                        if !todo.subtasks.isEmpty {
                            let done = todo.subtasks.filter(\.isCompleted).count
                            Text("\(done)/\(todo.subtasks.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var proposedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pendingProposals.isEmpty {
                emptyRow("Nothing proposed from meetings", systemImage: "tray")
            } else {
                ForEach(pendingProposals.prefix(6)) { proposal in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proposal.title).font(.callout).lineLimit(2)
                            HStack(spacing: 4) {
                                Text(proposal.meetingTitle)
                                if let who = proposal.saidBy { Text("· \(who)") }
                            }
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { proposalService.decline(proposal) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Decline")
                        Button { _ = proposalService.accept(proposal) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(.borderless).help("Add to todos")
                    }
                }
                Button("Review all in Todos") {
                    router.selection = .todos
                    openMainWindow()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recentEntries.isEmpty {
                emptyRow("No entries yet", systemImage: "clock")
            } else {
                ForEach(recentEntries) { entry in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(entry.displayColor).frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title.isEmpty ? "(untitled)" : entry.title).font(.callout).lineLimit(1)
                            Text([entry.project?.name, entry.customer?.name].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let d = entry.duration {
                            Text(DurationFormat.hoursMinutes(d))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Button {
                            controller.startManual(title: entry.title, role: entry.role,
                                                   project: entry.project, customer: entry.customer)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(controller.isRunning)
                        .help("Start again")
                    }
                }
            }
        }
    }

    private func emptyRow(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }

    private func addTodo() {
        let trimmed = newTodoTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (activeRootTodos.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(Todo(title: trimmed, sortOrder: nextOrder))
        try? modelContext.save()
        newTodoTitle = ""
        quickAddFocused = true
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button { openMainWindow() } label: {
                Label("Open Hansel", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .keyboardShortcut(",", modifiers: [.command])
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            IconButton(systemImage: "power", help: "Quit Hansel") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command])
        }
        .font(.callout)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hhmm(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Today's numbers for the menu header and the Dashboard.
struct TodaySummary {
    let strip: DayStripModel
    let colors: [String: Color]
    let entryCount: Int
    let billablePercent: Int

    @MainActor
    static func load(context: ModelContext, now: Date = Date()) -> TodaySummary {
        let dayStart = Calendar.current.startOfDay(for: now)
        let descriptor = FetchDescriptor<TimeEntry>(
            // Running entries (no end) count as ending now. A force unwrap inside
            // #Predicate silently matched nothing.
            predicate: #Predicate<TimeEntry> { ($0.endAt ?? now) > dayStart },
            sortBy: [SortDescriptor(\.startAt)]
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        var colors: [String: Color] = [:]
        let items = entries.map { entry -> DayStripModel.Item in
            let key = entry.project?.id.uuidString ?? "none"
            colors[key] = entry.displayColor
            return .init(id: entry.id, start: entry.startAt, end: entry.endAt, colorKey: key)
        }
        let strip = DayStripModel.make(items: items, day: now, now: now)
        var billable: TimeInterval = 0
        for entry in entries where entry.billableCached {
            let end = min(entry.endAt ?? now, now)
            billable += max(0, end.timeIntervalSince(max(entry.startAt, dayStart)))
        }
        let percent = strip.trackedSeconds > 0 ? Int((billable / strip.trackedSeconds * 100).rounded()) : 0
        return TodaySummary(strip: strip, colors: colors, entryCount: entries.count, billablePercent: percent)
    }
}
