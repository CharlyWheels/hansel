import XCTest
@testable import TimeTracker

final class CustomerMatcherTests: XCTestCase {

    private func customer(_ name: String, _ domains: String) -> Customer {
        let c = Customer(name: name)
        c.emailDomains = domains
        return c
    }

    func test_matchesAListedDomainAndItsSubdomains() {
        let acme = customer("Acme", "acme.com, @acme.co.uk")
        let globex = customer("Globex", "globex.io")
        XCTAssertEqual(CustomerMatcher.customer(forDomains: ["gmail.com", "eu.acme.com"], in: [globex, acme])?.name, "Acme")
        XCTAssertEqual(CustomerMatcher.customer(forDomains: ["acme.co.uk"], in: [globex, acme])?.name, "Acme")
        XCTAssertEqual(CustomerMatcher.customer(forDomains: ["globex.io"], in: [globex, acme])?.name, "Globex")
    }

    func test_noMatchWithoutDomainsOrForLookalikes() {
        let acme = customer("Acme", "acme.com")
        XCTAssertNil(CustomerMatcher.customer(forDomains: [], in: [acme]))
        XCTAssertNil(CustomerMatcher.customer(forDomains: ["notacme.com"], in: [acme]))
        XCTAssertNil(CustomerMatcher.customer(forDomains: ["acme.com"], in: [customer("Empty", "")]))
    }

    func test_domainOfEmail() {
        XCTAssertEqual(CustomerMatcher.domain(ofEmail: "Ana@Acme.com"), "acme.com")
        XCTAssertNil(CustomerMatcher.domain(ofEmail: "not-an-email"))
    }
}
