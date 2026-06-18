import Foundation

enum BillableResolver {
    /// Entry is billable only if role AND project AND customer all exist and are flagged billable.
    /// Any missing dimension ⇒ non-billable.
    static func resolve(role: Role?, project: Project?, customer: Customer?) -> Bool {
        guard let role, let project, let customer else { return false }
        return role.defaultBillable && project.defaultBillable && customer.defaultBillable
    }
}
