import Foundation

/// Reads the aliases listed on each customer and attributes things to customers with
/// them: a meeting by its attendees' email domains, and (for the closed customer list)
/// a new name or alias that would duplicate an existing customer.
enum CustomerMatcher {

    struct Alias: Equatable, Hashable {
        enum Kind: String, CaseIterable {
            case domain, slackChannel, contact, name
        }
        var kind: Kind
        /// Lowercased, without the leading `@` of a domain or `#` of a channel.
        var value: String
    }

    static func domain(ofEmail email: String) -> String? {
        let parts = email.lowercased().split(separator: "@")
        guard parts.count == 2, parts[1].contains(".") else { return nil }
        return String(parts[1])
    }

    /// One alias as typed, its kind read from its shape: `#x` a Slack channel,
    /// `a@b.c` or `@handle` a contact, `x.y` or `@x.y` an email domain, anything else
    /// a name or abbreviation. Nil for blank input.
    static func alias(_ raw: String) -> Alias? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            let channel = String(text.dropFirst())
            return channel.isEmpty ? nil : Alias(kind: .slackChannel, value: channel)
        }
        if text.hasPrefix("@") {
            let rest = String(text.dropFirst())
            guard !rest.isEmpty else { return nil }
            let looksLikeDomain = rest.contains(".") && !rest.contains("@") && !rest.contains(" ")
            return Alias(kind: looksLikeDomain ? .domain : .contact, value: rest)
        }
        if text.contains("@") { return Alias(kind: .contact, value: text) }
        if text.contains("."), !text.contains(" ") { return Alias(kind: .domain, value: text) }
        return Alias(kind: .name, value: text)
    }

    /// Every alias in a comma-separated list, duplicates dropped.
    static func aliases(in list: String) -> [Alias] {
        var seen = Set<Alias>()
        return list.split(separator: ",").compactMap { alias(String($0)) }.filter { seen.insert($0).inserted }
    }

    static func aliases(of customer: Customer) -> [Alias] { aliases(in: customer.aliases) }

    static func domains(of customer: Customer) -> [String] {
        aliases(of: customer).filter { $0.kind == .domain }.map(\.value)
    }

    /// The first customer owning one of the domains. A subdomain matches its parent
    /// ("eu.acme.com" matches "acme.com").
    static func customer(forDomains attendeeDomains: [String], in customers: [Customer]) -> Customer? {
        guard !attendeeDomains.isEmpty else { return nil }
        for domain in attendeeDomains {
            if let hit = customers.first(where: { customer in
                domains(of: customer).contains { domain == $0 || domain.hasSuffix("." + $0) }
            }) {
                return hit
            }
        }
        return nil
    }

    // MARK: - Closed list

    /// What a name is compared by: letters and digits only, lowercased, so "Hugo
    /// Boss", "hugo boss" and "HugoBoss" are the same customer.
    static func nameKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    struct Conflict: Equatable {
        /// The name or alias, as given, that is already taken.
        var term: String
        var customerName: String

        var message: String { "\"\(term)\" already belongs to the customer \"\(customerName)\"." }
    }

    /// The first of `name` and `aliases` that another customer already goes by, if
    /// any. Names and name-like aliases clash with each other's names and name
    /// aliases; domains, channels and contacts with the same kind.
    static func conflict(
        name: String?,
        aliases: String?,
        excluding excluded: Customer? = nil,
        in customers: [Customer]
    ) -> Conflict? {
        let others = customers.filter { $0.id != excluded?.id }
        func owner(ofNameKey key: String) -> Customer? {
            guard !key.isEmpty else { return nil }
            return others.first { other in
                nameKey(other.name) == key
                    || Self.aliases(of: other).contains { $0.kind == .name && nameKey($0.value) == key }
            }
        }
        if let name, let hit = owner(ofNameKey: nameKey(name)) {
            return Conflict(term: name.trimmingCharacters(in: .whitespaces), customerName: hit.name)
        }
        for raw in (aliases ?? "").split(separator: ",") {
            guard let alias = alias(String(raw)) else { continue }
            let term = raw.trimmingCharacters(in: .whitespaces)
            if alias.kind == .name {
                if let hit = owner(ofNameKey: nameKey(alias.value)) {
                    return Conflict(term: term, customerName: hit.name)
                }
            } else if let hit = others.first(where: { Self.aliases(of: $0).contains(alias) }) {
                return Conflict(term: term, customerName: hit.name)
            }
        }
        return nil
    }
}
