import Foundation
import SwiftData

/// Works out which time entry, project and customer a recorded meeting belongs to, from
/// what Hansel already knows. No model calls.
enum MeetingContextResolver {

    struct Resolution: Equatable {
        var projectID: UUID?
        var customerID: UUID?
        /// Where the project came from, shown to the user ("from your time entry").
        var source: Source?
    }

    enum Source: String, Equatable {
        case learned = "from your past corrections"
        case timeEntry = "from the meeting's time entry"
        case pastEntry = "from past entries with this title"
        case attendees = "from the attendees' email domains"
    }

    /// The entry that covers most of the meeting. It must cover at least half of it (or
    /// ten minutes of a long one), so an entry merely touching the edges is not taken.
    static func bestEntry(start: Date, end: Date?, entries: [TimeEntry], now: Date = Date()) -> TimeEntry? {
        let meetingEnd = end ?? start.addingTimeInterval(1800)
        let length = max(meetingEnd.timeIntervalSince(start), 60)
        let required = min(length / 2, 600)
        var best: (entry: TimeEntry, overlap: TimeInterval)?
        for entry in entries where entry.supersededByID == nil {
            let entryEnd = entry.endAt ?? now
            let overlap = min(entryEnd, meetingEnd).timeIntervalSince(max(entry.startAt, start))
            guard overlap >= required else { continue }
            if overlap > (best?.overlap ?? 0) { best = (entry, overlap) }
        }
        return best?.entry
    }

    /// Picks project and customer, strongest evidence first:
    /// 1. what the user chose for tasks from earlier meetings with this title;
    /// 2. the time entry covering this meeting, when it has a project;
    /// 3. the last confirmed entry with the same title;
    /// 4. the customer owning the attendees' email domain (and its only project, if one).
    static func resolve(
        title: String,
        attendeeDomains: [String],
        linkedEntry: TimeEntry?,
        learnedProjectID: UUID?,
        pastEntry: (project: Project?, customer: Customer?),
        projects: [Project],
        customers: [Customer]
    ) -> Resolution {
        let byAttendees = CustomerMatcher.customer(forDomains: attendeeDomains, in: customers)

        if let learnedProjectID, let project = projects.first(where: { $0.id == learnedProjectID }) {
            return Resolution(projectID: project.id,
                              customerID: (project.customer ?? byAttendees)?.id,
                              source: .learned)
        }
        if let entry = linkedEntry, let project = entry.project {
            return Resolution(projectID: project.id,
                              customerID: (entry.customer ?? project.customer ?? byAttendees)?.id,
                              source: .timeEntry)
        }
        if let project = pastEntry.project {
            return Resolution(projectID: project.id,
                              customerID: (pastEntry.customer ?? project.customer ?? byAttendees)?.id,
                              source: .pastEntry)
        }
        let customer = linkedEntry?.customer ?? pastEntry.customer ?? byAttendees
        if let customer {
            let theirs = projects.filter { $0.customer?.id == customer.id }
            return Resolution(projectID: theirs.count == 1 ? theirs[0].id : nil,
                              customerID: customer.id,
                              source: .attendees)
        }
        return Resolution()
    }

    /// `resolve` with its inputs fetched from the store.
    @MainActor
    static func resolve(record: MeetingRecord, learnedProjectID: UUID?, context: ModelContext) -> Resolution {
        let linked = record.linkedEntryID.flatMap { id in
            try? context.fetch(FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.id == id })).first
        }
        let (_, project, customer) = CalendarService.classify(title: record.title, context: context)
        return resolve(
            title: record.title,
            attendeeDomains: record.attendeeDomains,
            linkedEntry: linked,
            learnedProjectID: learnedProjectID,
            pastEntry: (project, customer),
            projects: (try? context.fetch(FetchDescriptor<Project>())) ?? [],
            customers: (try? context.fetch(FetchDescriptor<Customer>())) ?? []
        )
    }
}
