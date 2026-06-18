import XCTest
@testable import TimeTracker

final class BillableResolverTests: XCTestCase {
    func test_allBillable_isBillable() {
        let c = Customer(name: "A", defaultBillable: true)
        let p = Project(name: "P", customer: c, defaultBillable: true)
        let r = Role(name: "R", defaultBillable: true)
        XCTAssertTrue(BillableResolver.resolve(role: r, project: p, customer: c))
    }

    func test_anyNonBillable_isNotBillable() {
        let c = Customer(name: "A", defaultBillable: true)
        let p = Project(name: "P", customer: c, defaultBillable: false)
        let r = Role(name: "R", defaultBillable: true)
        XCTAssertFalse(BillableResolver.resolve(role: r, project: p, customer: c))
    }

    func test_missingDimension_isNotBillable() {
        XCTAssertFalse(BillableResolver.resolve(role: nil, project: nil, customer: nil))
        let c = Customer(name: "A", defaultBillable: true)
        XCTAssertFalse(BillableResolver.resolve(role: nil, project: nil, customer: c))
    }

    func test_truthTable() {
        let cases: [(Bool, Bool, Bool, Bool)] = [
            // role, project, customer, expected
            (true,  true,  true,  true),
            (false, true,  true,  false),
            (true,  false, true,  false),
            (true,  true,  false, false),
            (false, false, false, false),
        ]
        for (r, p, c, expected) in cases {
            let role = Role(name: "R", defaultBillable: r)
            let customer = Customer(name: "C", defaultBillable: c)
            let project = Project(name: "P", customer: customer, defaultBillable: p)
            XCTAssertEqual(
                BillableResolver.resolve(role: role, project: project, customer: customer),
                expected,
                "role=\(r) project=\(p) customer=\(c)"
            )
        }
    }
}
