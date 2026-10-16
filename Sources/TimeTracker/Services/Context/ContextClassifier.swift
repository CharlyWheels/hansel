import Foundation

/// Decides which todo, or which customer, a piece of context belongs to.
///
/// Two independent opinions are combined. Hansel's own signals come first: the people's
/// email domains, the channel and contacts matched against customer aliases (strong),
/// and customer names mentioned in the text (weaker). The assistant that read the
/// source suggests a todo or customer with a confidence; it is checked against the list
/// rather than trusted. When they disagree, or neither is sure, the item waits in the
/// inbox: guessing would put context in the wrong dossier.
///
/// Pure: no model calls and no database, so every rule is testable.
enum ContextClassifier {

    /// The assistant's suggestion counts on its own from this confidence up.
    static let assistantThreshold = 0.7
    static let strongSignalConfidence = 0.9
    static let mentionConfidence = 0.6

    struct Input {
        var title: String
        var summary: String
        var participants: [String] = []
        var channel: String?
        /// The assistant's suggestion, as it gave it.
        var suggestedTodoID: UUID?
        var suggestedCustomer: String?
        var suggestedConfidence: Double?
    }

    struct Decision: Equatable {
        enum Outcome: Equatable {
            /// Belongs to the todo, or to the customer alone when `todoID` is nil.
            case assigned(todoID: UUID?, customerID: UUID)
            case inbox
            /// About a customer kept out of AI context: not stored at all.
            case drop
        }
        var outcome: Outcome
        var confidence: Double = 0
        var assignedBy: ContextItem.AssignedBy = .none
        var reason: String
        var suggestedTodoID: UUID?
        var suggestedCustomerID: UUID?
        var proposedCustomerName: String?
    }

    /// `todos` are the open ones; a suggestion of any other todo is not followed.
    static func classify(_ input: Input, customers: [Customer], todos: [Todo]) -> Decision {
        let strong = strongCustomers(input, customers: customers)
        let mentioned = CustomerMatcher.customers(mentionedIn: input.title + "\n" + input.summary, in: customers)

        let suggestedTodo = input.suggestedTodoID.flatMap { id in todos.first { $0.id == id } }
        let suggestedCustomer = input.suggestedCustomer.flatMap { resolveCustomer($0, in: customers) }
        let unknownCustomer = input.suggestedCustomer.flatMap {
            resolveCustomer($0, in: customers) == nil && !$0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : nil
        }
        var decision = Decision(
            outcome: .inbox, reason: "",
            suggestedTodoID: input.suggestedTodoID,
            suggestedCustomerID: suggestedCustomer?.id,
            proposedCustomerName: unknownCustomer
        )

        // Anything touching a customer kept out of AI context is left out entirely.
        let involved = strong + mentioned + [suggestedTodo?.effectiveCustomer, suggestedCustomer].compactMap { $0 }
        if involved.contains(where: \.excludedFromContext) || suggestedTodo?.isExcludedFromContext == true {
            decision.outcome = .drop
            decision.reason = "Kept out of AI context."
            return decision
        }

        let ruleSet = strong.isEmpty ? mentioned : strong
        let ruleCustomer = ruleSet.count == 1 ? ruleSet[0] : nil
        let ruleConfidence = strong.isEmpty ? mentionConfidence : strongSignalConfidence
        let ruleWhy = strong.isEmpty ? "mentions \(ruleCustomer?.name ?? "")" : "people or channel of \(ruleCustomer?.name ?? "")"
        let assistantConfidence = input.suggestedConfidence ?? 0
        let assistantSure = assistantConfidence >= assistantThreshold

        if ruleSet.count > 1 {
            // Several customers by Hansel's signals: only an assistant pick among them settles it.
            let names = ruleSet.map(\.name).joined(separator: ", ")
            if let todo = suggestedTodo, let owner = todo.effectiveCustomer,
               ruleSet.contains(where: { $0.id == owner.id }), assistantSure {
                return assign(&decision, todo: todo, customer: owner, confidence: assistantConfidence, by: .both,
                              reason: "Several customers (\(names)); the assistant picked \(todo.title).")
            }
            decision.reason = "Several customers: \(names)."
            return decision
        }

        if let todo = suggestedTodo {
            let owner = todo.effectiveCustomer
            if let ruleCustomer, let owner, ruleCustomer.id != owner.id {
                decision.reason = "Hansel says \(ruleCustomer.name), the assistant says \(todo.title) (\(owner.name))."
                return decision
            }
            if let ruleCustomer, owner?.id == ruleCustomer.id {
                return assign(&decision, todo: todo, customer: ruleCustomer,
                              confidence: max(assistantConfidence, ruleConfidence), by: .both,
                              reason: "The assistant and Hansel (\(ruleWhy)) agree.")
            }
            guard let customer = owner ?? ruleCustomer else {
                decision.reason = "The todo \(todo.title) has no customer yet."
                return decision
            }
            guard assistantSure else {
                decision.reason = "The assistant suggests \(todo.title), but is not sure."
                return decision
            }
            return assign(&decision, todo: todo, customer: customer, confidence: assistantConfidence, by: .assistant,
                          reason: "The assistant's choice.")
        }

        if let ruleCustomer, let suggestedCustomer, ruleCustomer.id != suggestedCustomer.id {
            decision.reason = "Hansel says \(ruleCustomer.name), the assistant says \(suggestedCustomer.name)."
            return decision
        }
        let customer: Customer?
        let by: ContextItem.AssignedBy
        let confidence: Double
        if let ruleCustomer {
            customer = ruleCustomer
            by = suggestedCustomer != nil ? .both : .rules
            confidence = suggestedCustomer != nil ? max(ruleConfidence, assistantConfidence) : ruleConfidence
        } else if let suggestedCustomer, assistantSure {
            customer = suggestedCustomer
            by = .assistant
            confidence = assistantConfidence
        } else {
            customer = nil
            by = .none
            confidence = 0
        }
        guard let customer else {
            if let unknownCustomer {
                decision.reason = "The assistant names a customer not in the list: \(unknownCustomer)."
            } else if let suggestedCustomer {
                decision.reason = "The assistant suggests \(suggestedCustomer.name), but is not sure."
            } else if input.suggestedTodoID != nil {
                decision.reason = "The suggested todo is not an open todo."
            } else {
                decision.reason = "No customer found."
            }
            return decision
        }
        // Weak signals alone (a name in the text) are not enough to assign.
        if by == .rules, strong.isEmpty {
            decision.suggestedCustomerID = customer.id
            decision.reason = "Mentions \(customer.name); confirm."
            return decision
        }
        let theirs = todos.filter { $0.parent == nil && $0.effectiveCustomer?.id == customer.id }
        if theirs.count == 1 {
            return assign(&decision, todo: theirs[0], customer: customer, confidence: confidence, by: by,
                          reason: "\(customer.name)'s only open todo.")
        }
        decision.outcome = .assigned(todoID: nil, customerID: customer.id)
        decision.confidence = confidence
        decision.assignedBy = by
        decision.reason = theirs.isEmpty
            ? "\(customer.name), which has no open todo."
            : "\(customer.name); several open todos, so the customer only."
        return decision
    }

    private static func assign(
        _ decision: inout Decision, todo: Todo, customer: Customer, confidence: Double,
        by: ContextItem.AssignedBy, reason: String
    ) -> Decision {
        decision.outcome = .assigned(todoID: todo.id, customerID: customer.id)
        decision.confidence = min(confidence, 1)
        decision.assignedBy = by
        decision.reason = reason
        return decision
    }

    /// Customers owning a participant's email domain or contact, or the channel.
    static func strongCustomers(_ input: Input, customers: [Customer]) -> [Customer] {
        var found: [Customer] = []
        func add(_ customer: Customer?) {
            if let customer, !found.contains(where: { $0.id == customer.id }) { found.append(customer) }
        }
        for raw in input.participants {
            let person = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let handle = person.hasPrefix("@") ? String(person.dropFirst()) : person
            if let domain = CustomerMatcher.domain(ofEmail: person) {
                add(CustomerMatcher.customer(forDomains: [domain], in: customers))
            }
            add(customers.first { CustomerMatcher.aliases(of: $0).contains { $0.kind == .contact && $0.value == handle } })
        }
        if let raw = input.channel?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty {
            let channel = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
            add(customers.first { CustomerMatcher.aliases(of: $0).contains { $0.kind == .slackChannel && $0.value == channel } })
        }
        return found
    }

    /// A customer by id, exact name or name alias.
    static func resolveCustomer(_ reference: String, in customers: [Customer]) -> Customer? {
        let text = reference.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let id = UUID(uuidString: text), let hit = customers.first(where: { $0.id == id }) { return hit }
        let key = CustomerMatcher.nameKey(text)
        guard !key.isEmpty else { return nil }
        return customers.first { customer in
            CustomerMatcher.nameKey(customer.name) == key
                || CustomerMatcher.aliases(of: customer).contains { $0.kind == .name && CustomerMatcher.nameKey($0.value) == key }
        }
    }
}
