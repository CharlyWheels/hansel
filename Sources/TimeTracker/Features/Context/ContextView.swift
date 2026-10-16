import SwiftUI
import SwiftData

/// Everything collected about the user's work — meetings, Slack, email, Teams, the
/// calendar, Confluence — and the inbox of what could not be placed with confidence.
/// Each decision here teaches the next collection.
struct ContextView: View {
    @Environment(ContextService.self) private var service

    // Plain queries filtered in Swift: a #Predicate in @Query can stall the type checker.
    @Query(sort: [SortDescriptor(\ContextItem.occurredAt, order: .reverse)]) private var items: [ContextItem]
    @Query(sort: [SortDescriptor(\Todo.sortOrder)]) private var todos: [Todo]
    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]

    @State private var filter: ContextItem.Status = .unassigned
    @State private var search = ""
    @State private var assigning: ContextItem?

    private var shown: [ContextItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            item.status == filter
                && (q.isEmpty || item.title.lowercased().contains(q) || item.summary.lowercased().contains(q))
        }
    }

    private func count(_ status: ContextItem.Status) -> Int { items.filter { $0.status == status }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader("Context", subtitle: "\(items.count) item\(items.count == 1 ? "" : "s")") {
                    EmptyView()
                }
                HStack {
                    Picker("Show", selection: $filter) {
                        Text("Inbox (\(count(.unassigned)))").tag(ContextItem.Status.unassigned)
                        Text("Assigned (\(count(.assigned)))").tag(ContextItem.Status.assigned)
                        Text("Discarded (\(count(.discarded)))").tag(ContextItem.Status.discarded)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    Spacer()
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(
                    filter == .unassigned ? "Inbox empty" : "Nothing here",
                    systemImage: filter == .unassigned ? "tray" : "doc.text.magnifyingglass",
                    description: Text(filter == .unassigned
                        ? "Meetings, messages and emails Hansel could not place with confidence wait here."
                        : "Nothing matches.")
                )
            } else {
                List(shown) { item in
                    row(item)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Context")
        .sheet(item: $assigning) { item in
            ContextAssignSheet(item: item, todos: todos, customers: customers)
        }
    }

    private func row(_ item: ContextItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.source.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                    if let link = item.url.flatMap(URL.init(string:)) {
                        Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                            .help("Open the original")
                    }
                }
                Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    Chip(text: item.source.label)
                    if let channel = item.channel { Chip(text: "#" + channel) }
                    Chip(text: item.occurredAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    if let target = target(of: item) {
                        Chip(text: target, systemImage: item.todoID == nil ? "building.2" : "checklist", color: .accentColor)
                    }
                }
                if !item.reason.isEmpty {
                    Text(item.reason).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(item.status == .assigned ? "Change…" : "Assign…") { assigning = item }
                if item.status == .discarded || (item.status == .assigned && item.isUserDecided) {
                    Button("Back to inbox") { service.reopen(item) }
                } else if item.status != .discarded {
                    Button("Discard") { service.discard(item) }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func target(of item: ContextItem) -> String? {
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
