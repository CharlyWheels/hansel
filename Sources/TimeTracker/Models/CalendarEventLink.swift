import Foundation
import SwiftData

@Model
final class CalendarEventLink {
    @Attribute(.unique) var eventIdentifier: String
    var linkedEntryID: UUID?
    var lastSeenStart: Date
    var lastSeenTitle: String
    var lastFired: Date?

    init(
        eventIdentifier: String,
        linkedEntryID: UUID? = nil,
        lastSeenStart: Date,
        lastSeenTitle: String,
        lastFired: Date? = nil
    ) {
        self.eventIdentifier = eventIdentifier
        self.linkedEntryID = linkedEntryID
        self.lastSeenStart = lastSeenStart
        self.lastSeenTitle = lastSeenTitle
        self.lastFired = lastFired
    }
}
