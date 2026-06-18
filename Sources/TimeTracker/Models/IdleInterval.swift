import Foundation
import SwiftData

@Model
final class IdleInterval {
    var start: Date
    var end: Date?

    init(start: Date = Date(), end: Date? = nil) {
        self.start = start
        self.end = end
    }

    var duration: TimeInterval? {
        guard let end else { return nil }
        return end.timeIntervalSince(start)
    }
}
