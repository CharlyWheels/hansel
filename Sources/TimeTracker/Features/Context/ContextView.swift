import SwiftUI
import SwiftData

enum ContextSelection: Hashable {
    case inbox
    case discarded
    case customer(UUID)
    case todo(UUID)
}

/// Everything collected about the user's work, read per customer and per todo: each
/// one's dossier and the meetings, messages, emails and pages behind it. The inbox holds
/// what could not be placed with confidence; deciding there teaches the next collection.
struct ContextView: View {
    @Environment(MainWindowRouter.self) private var router
    @Environment(ContextRunner.self) private var runner

    // Plain queries filtered in Swift: a #Predicate in @Query can stall the type checker.
    @Query(sort: [SortDescriptor(\ContextItem.occurredAt, order: .reverse)]) private var items: [ContextItem]
    @Query(sort: [SortDescriptor(\Todo.sortOrder), SortDescriptor(\Todo.createdAt)]) private var todos: [Todo]
    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]

    private var visibleCustomers: [Customer] { customers.filter { !$0.excludedFromContext } }

    private func openRoots(of customer: Customer?) -> [Todo] {
        todos.filter {
            $0.parent == nil && !$0.isCompleted && !$0.isExcludedFromContext
                && $0.effectiveCustomer?.id == customer?.id
        }
    }

    /// Open top-level todos with no dossier and nothing collected yet.
    private var todosWithoutContext: [Todo] {
        let withItems = Set(items.compactMap(\.todoID))
        return todos.filter { todo in
            todo.parent == nil && !todo.isCompleted && !todo.isExcludedFromContext && todo.dossier.isEmpty
                && !DossierService.subtree(todo).contains { withItems.contains($0.id) }
        }
    }

    var body: some View {
        @Bindable var router = router
        HSplitView {
            sidebar(selection: $router.contextSelection)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            VStack(spacing: 0) {
                RunnerBanner()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Context")
        .toolbar {
            ToolbarItemGroup {
                let fresh = todosWithoutContext
                if !fresh.isEmpty {
                    Button {
                        runner.gather(fresh.map(\.id))
                    } label: {
                        Label("Gather context for \(fresh.count) new todo\(fresh.count == 1 ? "" : "s")",
                              systemImage: "sparkle.magnifyingglass")
                    }
                    .disabled(runner.isRunning)
                    .help("Ask Codex to find everything about: " + fresh.map(\.title).joined(separator: ", "))
                }
                Button {
                    runner.collectEverything()
                } label: {
                    Label("Collect now", systemImage: "arrow.down.circle")
                }
                .disabled(runner.isRunning)
                .help("Ask Codex for everything new in Slack, email, Teams, the calendar, Confluence and GitHub")
            }
        }
    }

    // MARK: - Sidebar

    private func sidebar(selection: Binding<ContextSelection>) -> some View {
        List(selection: Binding<ContextSelection?>(get: { selection.wrappedValue }, set: { if let v = $0 { selection.wrappedValue = v } })) {
            Section {
                Label("Inbox", systemImage: "tray")
                    .badge(items.filter { $0.status == .unassigned }.count)
                    .tag(ContextSelection.inbox)
            }
            Section("Customers") {
                ForEach(visibleCustomers) { customer in
                    Label(customer.name, systemImage: "building.2")
                        .badge(items.filter { $0.status == .assigned && $0.customerID == customer.id }.count)
                        .tag(ContextSelection.customer(customer.id))
                    ForEach(openRoots(of: customer)) { root in
                        todoRows(root, depth: 1)
                    }
                }
            }
            let loose = openRoots(of: nil)
            if !loose.isEmpty {
                Section("No customer") {
                    ForEach(loose) { root in todoRows(root, depth: 0) }
                }
            }
            Section {
                Label("Discarded", systemImage: "trash")
                    .badge(items.filter { $0.status == .discarded }.count)
                    .tag(ContextSelection.discarded)
            }
        }
        .listStyle(.sidebar)
    }

    private func todoRows(_ todo: Todo, depth: Int) -> AnyView {
        AnyView(Group {
            HStack(spacing: 6) {
                Image(systemName: todo.dossier.isEmpty ? "circle.dashed" : "doc.text")
                    .foregroundStyle(todo.dossier.isEmpty ? Color.secondary : Color.accentColor)
                    .help(todo.dossier.isEmpty ? "No dossier yet" : "Has a dossier")
                Text(todo.title.isEmpty ? "(untitled)" : todo.title).lineLimit(1)
                if runner.isGathering(todo.id) { ProgressView().controlSize(.small) }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .tag(ContextSelection.todo(todo.id))
            ForEach(todo.orderedSubtasks.filter { !$0.isCompleted }) { sub in
                todoRows(sub, depth: depth + 1)
            }
        })
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch router.contextSelection {
        case .inbox:
            ContextItemList(items: items.filter { $0.status == .unassigned }, todos: todos, customers: customers,
                            title: "Inbox",
                            empty: ("Inbox empty", "tray", "Meetings, messages and emails Hansel could not place with confidence wait here."))
        case .discarded:
            ContextItemList(items: items.filter { $0.status == .discarded }, todos: todos, customers: customers,
                            title: "Discarded",
                            empty: ("Nothing discarded", "trash", "Items you discard from the inbox are kept here."))
        case let .customer(id):
            if let customer = customers.first(where: { $0.id == id }) {
                CustomerContextDetail(customer: customer, items: items, todos: todos, customers: customers)
            } else {
                gone
            }
        case let .todo(id):
            if let todo = todos.first(where: { $0.id == id }) {
                TodoContextDetail(todo: todo, items: items, todos: todos, customers: customers)
            } else {
                gone
            }
        }
    }

    private var gone: some View {
        ContentUnavailableView("Not found", systemImage: "questionmark.folder",
                               description: Text("It was deleted. Pick something else on the left."))
    }
}

/// What the collection running in the background is doing, and how the last one ended.
private struct RunnerBanner: View {
    @Environment(ContextRunner.self) private var runner
    @State private var hidden: String?

    var body: some View {
        if runner.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(runner.current == .everything
                     ? "Codex is collecting everything new. This takes a few minutes; items and dossiers appear as they arrive."
                     : "Codex is gathering context for the chosen todos. This takes a few minutes; items and dossiers appear as they arrive.")
                    .font(.callout)
                Spacer()
                if let started = runner.startedAt {
                    Text(started, style: .timer).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.blue.opacity(0.08))
        } else if let message = runner.lastMessage, message != hidden {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: runner.lastFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(runner.lastFailed ? .orange : .green)
                Text(message).font(.callout).textSelection(.enabled).lineLimit(8)
                Spacer()
                Button { hidden = message } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background((runner.lastFailed ? Color.orange : Color.green).opacity(0.08))
        }
    }
}

// MARK: - Customer and todo pages

private struct CustomerContextDetail: View {
    @Bindable var customer: Customer
    let items: [ContextItem]
    let todos: [Todo]
    let customers: [Customer]

    @Environment(\.modelContext) private var modelContext
    @Environment(MainWindowRouter.self) private var router

    private var theirTodos: [Todo] {
        todos.filter { $0.parent == nil && !$0.isCompleted && $0.effectiveCustomer?.id == customer.id }
    }

    private var theirItems: [ContextItem] {
        let ids = Set(theirTodos.flatMap(DossierService.subtree).map(\.id))
        return items.filter { item in
            item.status == .assigned && (item.customerID == customer.id || (item.todoID.map(ids.contains) ?? false))
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(customer.name).font(.title2.weight(.semibold))
                    Text("\(theirTodos.count) open todo\(theirTodos.count == 1 ? "" : "s") · \(theirItems.count) context item\(theirItems.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
            DossierSection(dossier: $customer.dossier, updatedAt: customer.dossierUpdatedAt) {
                customer.dossierUpdatedAt = Date()
                try? modelContext.save()
            }
            if !theirTodos.isEmpty {
                Section("Todos") {
                    ForEach(theirTodos) { todo in
                        Button { router.contextSelection = .todo(todo.id) } label: {
                            HStack {
                                Image(systemName: todo.dossier.isEmpty ? "circle.dashed" : "doc.text")
                                Text(todo.title)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ContextItemsSection(items: theirItems, todos: todos, customers: customers, showTarget: true)
        }
        .formStyle(.grouped)
    }
}

private struct TodoContextDetail: View {
    @Bindable var todo: Todo
    let items: [ContextItem]
    let todos: [Todo]
    let customers: [Customer]

    @Environment(\.modelContext) private var modelContext
    @Environment(ContextRunner.self) private var runner

    private var theirItems: [ContextItem] {
        let ids = Set(DossierService.subtree(todo).map(\.id))
        return items.filter { $0.status == .assigned && ($0.todoID.map(ids.contains) ?? false) }
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(todo.breadcrumbPath).font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            if let customer = todo.effectiveCustomer { Chip(text: customer.name, systemImage: "building.2") }
                            if let project = todo.inheritedProject {
                                Chip(text: project.name, systemImage: "folder", color: project.displayColor)
                            }
                            Chip(text: "\(theirItems.count) context item\(theirItems.count == 1 ? "" : "s")", systemImage: "tray.full")
                        }
                        if let notes = todo.notes, !notes.isEmpty {
                            Text(notes).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    GatherButton(todo: todo)
                }
            }
            DossierSection(dossier: $todo.dossier, updatedAt: todo.dossierUpdatedAt) {
                todo.dossierUpdatedAt = Date()
                try? modelContext.save()
            }
            ContextItemsSection(items: theirItems, todos: todos, customers: customers, showTarget: !todo.subtasks.isEmpty)
        }
        .formStyle(.grouped)
    }
}

/// Asks Codex to search every source for this todo, however old, and write its dossier.
struct GatherButton: View {
    let todo: Todo
    @Environment(ContextRunner.self) private var runner

    var body: some View {
        if runner.isGathering(todo.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Gathering…").foregroundStyle(.secondary)
            }
        } else {
            Button {
                runner.gather([todo.id])
            } label: {
                Label(todo.dossier.isEmpty ? "Gather context" : "Gather more context", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(runner.isRunning || todo.isExcludedFromContext)
            .help(runner.isRunning
                  ? "A collection is already running."
                  : "Codex searches Slack, email, Teams, the calendar, Confluence and GitHub for this todo and writes its dossier. Takes a few minutes.")
        }
    }
}

// MARK: - Items

/// The inbox or the discarded items, as a page of its own.
private struct ContextItemList: View {
    let items: [ContextItem]
    let todos: [Todo]
    let customers: [Customer]
    let title: String
    let empty: (title: String, image: String, text: String)

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(empty.title, systemImage: empty.image, description: Text(empty.text))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                ContextItemsSection(items: items, todos: todos, customers: customers, showTarget: true, header: title)
            }
            .formStyle(.grouped)
        }
    }
}

private struct ContextItemsSection: View {
    let items: [ContextItem]
    let todos: [Todo]
    let customers: [Customer]
    var showTarget: Bool
    var header: String = "Context"

    @State private var assigning: ContextItem?

    var body: some View {
        Section {
            if items.isEmpty {
                Text("Nothing collected yet.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                ContextItemRow(item: item, todos: todos, customers: customers, showTarget: showTarget) {
                    assigning = item
                }
            }
        } header: {
            Text("\(header) (\(items.count))")
        }
        .sheet(item: $assigning) { item in
            ContextAssignSheet(item: item, todos: todos, customers: customers)
        }
    }
}

private struct ContextItemRow: View {
    let item: ContextItem
    let todos: [Todo]
    let customers: [Customer]
    let showTarget: Bool
    let onAssign: () -> Void

    @Environment(ContextService.self) private var service
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.source.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                    if let link = item.url.flatMap(URL.init(string:)) {
                        Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                            .help("Open the original")
                    }
                }
                Text(item.summary).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Chip(text: item.source.label)
                    if let channel = item.channel { Chip(text: "#" + channel) }
                    Chip(text: item.occurredAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    if showTarget, let target = target {
                        Chip(text: target, systemImage: item.todoID == nil ? "building.2" : "checklist", color: .accentColor)
                    }
                }
                if expanded {
                    if !item.details.isEmpty {
                        Text(item.details).font(.callout).textSelection(.enabled).padding(.top, 4)
                    }
                    if !item.participants.isEmpty {
                        Text(item.participants.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.reason.isEmpty {
                        Text(item.reason).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.borderless)
                Button(item.status == .assigned ? "Move…" : "Assign…", action: onAssign)
                if item.status == .discarded {
                    Button("Back to inbox") { service.reopen(item) }
                } else {
                    Button("Discard") { service.discard(item) }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var target: String? {
        if let id = item.todoID, let todo = todos.first(where: { $0.id == id }) { return todo.breadcrumbPath }
        guard let id = item.customerID, let customer = customers.first(where: { $0.id == id }) else { return nil }
        return item.status == .assigned ? customer.name : "\(customer.name)?"
    }
}

/// Puts an item on a todo, or on a customer when no todo fits, and offers the aliases
/// that would have found it.
struct ContextAssignSheet: View {
    let item: ContextItem
    let todos: [Todo]
    let customers: [Customer]

    @Environment(ContextService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var todoID: UUID?
    @State private var customerID: UUID?
    @State private var aliases: Set<String> = []

    private var openTodos: [Todo] {
        todos.filter { !$0.isCompleted && !$0.isExcludedFromContext }.sorted { $0.breadcrumbPath < $1.breadcrumbPath }
    }

    private var chosenCustomer: Customer? {
        if let todoID, let todo = todos.first(where: { $0.id == todoID }) { return todo.effectiveCustomer }
        return customerID.flatMap { id in customers.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Text(item.title).font(.headline)
                    Text(item.summary).foregroundStyle(.secondary)
                    if !item.participants.isEmpty {
                        Text(item.participants.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Belongs to") {
                    Picker("Todo", selection: $todoID) {
                        Text("No todo (customer only)").tag(UUID?.none)
                        ForEach(openTodos) { todo in
                            Text(todo.breadcrumbPath + (todo.effectiveCustomer.map { " — \($0.name)" } ?? ""))
                                .tag(UUID?.some(todo.id))
                        }
                    }
                    if todoID == nil {
                        Picker("Customer", selection: $customerID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(customers.filter { !$0.excludedFromContext }) { customer in
                                Text(customer.name).tag(UUID?.some(customer.id))
                            }
                        }
                    }
                    if let name = item.proposedCustomerName {
                        Text("The assistant named a customer not in the list: \(name). Add it in Customers first if it is one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let customer = chosenCustomer {
                    let candidates = service.aliasCandidates(for: item, customer: customer)
                    if !candidates.isEmpty {
                        Section("Recognise it next time") {
                            ForEach(candidates, id: \.self) { alias in
                                Toggle("Add \(alias) to \(customer.name)'s aliases", isOn: Binding(
                                    get: { aliases.contains(alias) },
                                    set: { if $0 { aliases.insert(alias) } else { aliases.remove(alias) } }
                                ))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Assign") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(todoID == nil && customerID == nil)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            let open = Set(openTodos.map(\.id))
            todoID = [item.todoID, item.suggestedTodoID].compactMap { $0 }.first { open.contains($0) }
            customerID = item.customerID ?? item.suggestedCustomerID
        }
    }

    private func save() {
        if let todoID, let todo = todos.first(where: { $0.id == todoID }) {
            service.assign(item, todo: todo)
        } else if let customerID, let customer = customers.first(where: { $0.id == customerID }) {
            service.assign(item, customer: customer)
        }
        if let customer = chosenCustomer {
            for alias in aliases.sorted() { service.addAlias(alias, to: customer) }
        }
    }
}
