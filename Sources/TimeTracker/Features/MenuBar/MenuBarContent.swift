import SwiftUI
import SwiftData

struct MenuBarContent: View {
    @Environment(TimerController.self) private var controller
    @Environment(EntryCompletionService.self) private var completion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @Query(sort: [SortDescriptor(\Project.name)]) private var projects: [Project]
    @Query(sort: [SortDescriptor(\Role.name)]) private var roles: [Role]
    @Query(
        filter: #Predicate<TimeEntry> { $0.endAt != nil },
        sort: [SortDescriptor(\TimeEntry.startAt, order: .reverse)]
    ) private var recentEntries: [TimeEntry]
    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)])
    private var allTodos: [Todo]

    @State private var newTodoTitle: String = ""

    private var activeTodos: [Todo] {
        allTodos.filter { !$0.isCompleted }
    }

    private var activeRootTodos: [Todo] {
        activeTodos.filter { $0.parent == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HanselBrandRow(iconSize: 20)
            Divider()
            if let prompt = completion.pendingPrompt {
                completionBanner(prompt)
                Divider()
            }
            if controller.isRunning {
                runningSection
            } else {
                idleSection
            }
            Divider()
            todosSection
            Divider()
            recentSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    // MARK: - Completion prompt banner

    @ViewBuilder
    private func completionBanner(_ prompt: EntryCompletionService.PendingPrompt) -> some View {
        switch prompt.kind {
        case .doneQuestion:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(prompt.message)
                        .font(.callout)
                        .lineLimit(3)
                }
                HStack {
                    Button("End entry") { completion.confirmEnd() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    Spacer()
                    Button("Keep going") { completion.confirmContinue() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
        case .autoEndNotice:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.blue)
                Text(prompt.message)
                    .font(.callout)
                    .lineLimit(3)
                Spacer()
                Button("Dismiss") { completion.dismissNotice() }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: - Running

    @ViewBuilder
    private var runningSection: some View {
        if let entry = controller.runningEntry {
            @Bindable var entry = entry
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: Date.distantPast, by: 1.0)) { _ in
                    HStack {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text(DurationFormat.clock(controller.elapsed))
                            .monospacedDigit()
                            .font(.title3)
                        Spacer()
                        Button("Stop", systemImage: "stop.fill") { controller.stop() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .keyboardShortcut("s", modifiers: [.command])
                    }
                }
                TextField("What are you working on?", text: $entry.title)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: entry.title) { _, _ in saveEntry() }

                HStack(spacing: 6) {
                    rolePicker(selection: Binding(
                        get: { entry.role },
                        set: { entry.role = $0; entry.refreshBillableCache(); saveEntry() }
                    ))
                    projectPicker(selection: Binding(
                        get: { entry.project },
                        set: { new in
                            entry.project = new
                            if entry.customer == nil {
                                entry.customer = new?.customer
                            }
                            entry.refreshBillableCache()
                            saveEntry()
                        }
                    ))
                }

                todoPicker(selection: Binding(
                    get: { entry.linkedTodo },
                    set: { entry.linkedTodo = $0; saveEntry() }
                ))

                if let linked = entry.linkedTodo {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text(linked.breadcrumbPath)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(linked.inheritedDisplayColor ?? .secondary)
                }

                HStack {
                    billableBadge(entry)
                    Spacer()
                    if let customer = entry.customer {
                        Text(customer.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func saveEntry() {
        try? modelContext.save()
    }

    private func billableBadge(_ entry: TimeEntry) -> some View {
        let isBillable = BillableResolver.resolve(
            role: entry.role,
            project: entry.project,
            customer: entry.customer
        )
        return Label(isBillable ? "Billable" : "Non-billable", systemImage: isBillable ? "dollarsign.circle.fill" : "dollarsign.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(isBillable ? .green : .secondary)
    }

    // MARK: - Idle

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "timer").foregroundStyle(.secondary)
                Text("No timer running").foregroundStyle(.secondary)
                Spacer()
                Button("Start", systemImage: "play.fill") { controller.startManual() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(";", modifiers: [.command])
            }
            Text("Start a manual timer, or let the app auto-start from a calendar event or 10 min of activity (Phase 2+).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if recentEntries.isEmpty {
                Text("No entries yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(recentEntries.prefix(5)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                                .font(.caption)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if let p = entry.project {
                                    Text(p.name).font(.caption2).foregroundStyle(.secondary)
                                }
                                if let c = entry.customer {
                                    Text("· \(c.name)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                        if let d = entry.duration {
                            Text(DurationFormat.hoursMinutes(d))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            controller.startManual(
                                title: entry.title,
                                role: entry.role,
                                project: entry.project,
                                customer: entry.customer
                            )
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(controller.isRunning)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: [.command])
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command])
        }
        .font(.caption)
    }

    // MARK: - Pickers

    private func rolePicker(selection: Binding<Role?>) -> some View {
        Picker("Role", selection: selection) {
            Text("None").tag(Optional<Role>.none)
            ForEach(roles) { role in
                Text(role.name).tag(Optional(role))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func projectPicker(selection: Binding<Project?>) -> some View {
        Picker("Project", selection: selection) {
            Text("No project").tag(Optional<Project>.none)
            ForEach(projects) { project in
                Text(project.customer != nil ? "\(project.name) — \(project.customer!.name)" : project.name)
                    .tag(Optional(project))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func todoPicker(selection: Binding<Todo?>) -> some View {
        Picker("Todo", selection: selection) {
            Text("No todo").tag(Optional<Todo>.none)
            ForEach(activeTodos) { todo in
                Text(todo.breadcrumbPath).tag(Optional(todo))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    // MARK: - Todos

    private var todosSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Todos").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Quick add", text: $newTodoTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTodo)
                Button("Add", action: addTodo)
                    .disabled(newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if activeRootTodos.isEmpty {
                Text("No active todos").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(activeRootTodos.prefix(5)) { todo in
                    HStack(spacing: 6) {
                        Button {
                            todo.isCompleted = true
                            todo.completedAt = Date()
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        Text(todo.title.isEmpty ? "(untitled)" : todo.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(todo.inheritedDisplayColor ?? .primary)
                        Spacer()
                        if !todo.subtasks.isEmpty {
                            let done = todo.subtasks.filter(\.isCompleted).count
                            Text("\(done)/\(todo.subtasks.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func addTodo() {
        let trimmed = newTodoTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (activeRootTodos.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(Todo(title: trimmed, sortOrder: nextOrder))
        try? modelContext.save()
        newTodoTitle = ""
    }
}
