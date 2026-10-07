import Foundation
import SwiftData

/// Copies what the Analytics page needs from the store into `AnalyticsEngine` facts,
/// for a period and the one before it. Fetches are bounded by date.
@MainActor
enum AnalyticsLoader {

    static func input(for interval: DateInterval, context: ModelContext, now: Date = Date()) -> AnalyticsEngine.Input {
        let previous = AnalyticsEngine.previous(of: interval)
        let from = previous.start, to = interval.end
        var input = AnalyticsEngine.Input()

        let entries = (try? context.fetch(FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.startAt < to && ($0.endAt ?? now) > from }
        ))) ?? []
        input.entries = entries.map { e in
            AnalyticsEngine.EntryFact(
                id: e.id, title: e.title, start: e.startAt, end: min(e.endAt ?? now, now),
                projectID: e.project?.id, projectName: e.project?.name,
                customerID: e.customer?.id, customerName: e.customer?.name,
                roleID: e.role?.id, roleName: e.role?.name,
                billable: e.billableCached, source: e.source,
                humanConfirmed: e.isHumanConfirmed, todoTitle: e.linkedTodo?.title
            )
        }

        let start = interval.start
        let samples = (try? context.fetch(FetchDescriptor<ActivitySample>(
            predicate: #Predicate<ActivitySample> { $0.timestamp >= start && $0.timestamp < to },
            sortBy: [SortDescriptor(\.timestamp)]
        ))) ?? []
        input.samples = samples.map {
            .init(timestamp: $0.timestamp, bundleId: $0.bundleId, appName: $0.appName,
                  host: TitleTokenizer.hostKey(from: $0.url).map { host in
                      // The site, without the first path segment the segmenter keeps.
                      String(host.split(separator: "/").first ?? Substring(host))
                  })
        }

        let idle = (try? context.fetch(FetchDescriptor<IdleInterval>(
            predicate: #Predicate<IdleInterval> { $0.start < to && ($0.end ?? to) > start }
        ))) ?? []
        input.idleSeconds = idle.map { (start: $0.start, end: $0.end ?? now) }

        let meetings = (try? context.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate<MeetingRecord> { $0.startedAt >= from && $0.startedAt < to }
        ))) ?? []
        input.meetings = meetings.map {
            .init(id: $0.id, title: $0.title, start: $0.startedAt,
                  end: $0.endedAt ?? $0.startedAt.addingTimeInterval(1800))
        }
        let meetingIDs = Set(meetings.map(\.id))
        let profiles = Dictionary(((try? context.fetch(FetchDescriptor<SpeakerProfile>())) ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let speakers = ((try? context.fetch(FetchDescriptor<MeetingSpeaker>())) ?? [])
            .filter { meetingIDs.contains($0.meetingID) }
        input.speakers = speakers.map { s in
            let profile = s.profileID.flatMap { profiles[$0] }
            return .init(meetingID: s.meetingID, personName: profile?.name, isMe: profile?.isMe ?? false,
                         seconds: s.speechSeconds, onCall: s.track == "system")
        }

        let decisions = (try? context.fetch(FetchDescriptor<FocusDecision>(
            predicate: #Predicate<FocusDecision> { $0.createdAt >= start && $0.createdAt < to }
        ))) ?? []
        input.decisions = decisions.map { .init(at: $0.createdAt, kind: $0.kind, response: $0.userResponse) }

        let proposals = (try? context.fetch(FetchDescriptor<TodoProposal>(
            predicate: #Predicate<TodoProposal> { $0.createdAt >= start && $0.createdAt < to }
        ))) ?? []
        input.proposals = proposals.map { .init(meetingID: $0.meetingID, status: $0.status, createdAt: $0.createdAt) }

        let completed = (try? context.fetch(FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.isCompleted == true }
        ))) ?? []
        input.todosCompleted = completed.compactMap(\.completedAt)
        return input
    }
}
