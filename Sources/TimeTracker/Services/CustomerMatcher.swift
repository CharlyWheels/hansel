import Foundation

/// Attributes a meeting to a customer from its attendees' email domains, using the
/// domains listed on each customer.
enum CustomerMatcher {

    static func domain(ofEmail email: String) -> String? {
        let parts = email.lowercased().split(separator: "@")
        guard parts.count == 2, parts[1].contains(".") else { return nil }
        return String(parts[1])
    }

    static func domains(of customer: Customer) -> [String] {
        customer.emailDomains
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
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
}
