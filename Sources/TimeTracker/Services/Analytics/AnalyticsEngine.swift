import Foundation

/// Everything the Analytics page shows for one period, compared with the period before.
///
/// Pure: it works on plain value "facts" copied from the store, so the arithmetic is
/// unit-tested and the page only draws.
enum AnalyticsEngine {

    // MARK: - Inputs

    struct EntryFact: Equatable {
        let id: UUID
        var title: String = ""
        let start: Date
        let end: Date
        let projectID: UUID?
        let projectName: String?
        let customerID: UUID?
        let customerName: String?
        let roleID: UUID?
        let roleName: String?
        let billable: Bool
        let source: EntrySource
        let humanConfirmed: Bool
        let todoTitle: String?
    }

    struct SampleFact: Equatable {
        let timestamp: Date
        let bundleId: String
        let appName: String
        let host: String?
    }

    struct MeetingFact: Equatable {
        let id: UUID
        let title: String
        let start: Date
        let end: Date
    }

    struct SpeakerFact: Equatable {
        let meetingID: UUID
        let personName: String?
        let isMe: Bool
        let seconds: Double
        let onCall: Bool
    }

    struct DecisionFact: Equatable {
        let at: Date
        let kind: FocusDecisionKind
        let response: FocusUserResponse?
    }

    struct ProposalFact: Equatable {
        let meetingID: UUID
        let status: TodoProposal.Status
        let createdAt: Date
    }

    struct Input {
        var entries: [EntryFact] = []
        var samples: [SampleFact] = []
        var idleSeconds: [(start: Date, end: Date)] = []
        var meetings: [MeetingFact] = []
        var speakers: [SpeakerFact] = []
        var decisions: [DecisionFact] = []
        var proposals: [ProposalFact] = []
        var todosCompleted: [Date] = []
    }

    // MARK: - Output

    struct Delta: Equatable {
        let current: Double
        let previous: Double
        /// Relative change, nil when there is nothing to compare with.
        var change: Double? { previous > 0 ? (current - previous) / previous : nil }
    }

    struct Summary: Equatable {
        let tracked: Delta
        let billable: Delta
        let billableShare: Delta
        let perWorkingDay: Delta
        let workingDays: Int
        let meetingSeconds: Delta
        let entryCount: Int
        let averageEntry: TimeInterval
    }

    struct DaySlice: Equatable, Identifiable {
        let day: Date
        let key: String
        let name: String
        let seconds: TimeInterval
        var id: String { "\(day.timeIntervalSince1970)|\(key)" }
    }

    enum Dimension: String, CaseIterable, Identifiable {
        case project = "Project", customer = "Customer", role = "Role"
        var id: String { rawValue }
    }

    struct BreakdownLine: Equatable, Identifiable {
        let key: String
        let name: String
        let seconds: TimeInterval
        let billableSeconds: TimeInterval
        let previousSeconds: TimeInterval
        let share: Double
        var id: String { key }
        var billableShare: Double { seconds > 0 ? billableSeconds / seconds : 0 }
    }

    struct HeatCell: Equatable, Identifiable {
        /// 1 = Monday … 7 = Sunday.
        let weekday: Int
        let hour: Int
        let seconds: TimeInterval
        var id: Int { weekday * 100 + hour }
    }

    struct Ranked: Equatable, Identifiable {
        let name: String
        let seconds: TimeInterval
        var detail: String? = nil
        var id: String { name }
    }

    struct Focus: Equatable {
        let topApps: [Ranked]
        let topSites: [Ranked]
        /// Share of observed time in chat, mail and call apps.
        let communicationShare: Double
        let switchesPerHour: Double
        /// Entries of 45 minutes or more.
        let longBlocks: Int
        let longestBlock: TimeInterval
        let observedSeconds: TimeInterval
        let awaySeconds: TimeInterval
    }

    struct Meetings: Equatable {
        let count: Int
        let seconds: TimeInterval
        let averageLength: TimeInterval
        let shareOfTracked: Double
        /// Of the speech in diarised meetings, how much was the user.
        let myTalkShare: Double?
        let people: [Ranked]
        let longest: [Ranked]
        let proposalsAccepted: Int
        let proposalsDeclined: Int
        let proposalsPending: Int
    }

    struct Quality: Equatable {
        let unassignedShare: Double
        let unassignedSeconds: TimeInterval
        let reviewedShare: Double
        let bySource: [Ranked]
        let questionsAsked: Int
        let questionsAccepted: Int
        let questionsRejected: Int
        let questionsIgnored: Int
        let automaticSwitches: Int
        let todosCompleted: Int
    }

    struct Snapshot: Equatable {
        let interval: DateInterval
        let previousInterval: DateInterval
        let summary: Summary
        let days: [DaySlice]
        let heatmap: [HeatCell]
        let focus: Focus
        let meetings: Meetings
        let quality: Quality
        let colorKeys: [String]
        fileprivate let entries: [EntryFact]
        fileprivate let previousEntries: [EntryFact]

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.interval == b.interval && a.summary == b.summary && a.days == b.days
        }

        func breakdown(by dimension: Dimension) -> [BreakdownLine] {
            AnalyticsEngine.breakdown(entries, previous: previousEntries, interval: interval,
                                      previousInterval: previousInterval, by: dimension)
        }
    }

    // MARK: - Compute

    /// The period of the same length right before `interval`.
    static func previous(of interval: DateInterval, calendar: Calendar = .current) -> DateInterval {
        // Whole months compare with the previous whole month, not 30 days.
        let start = interval.start
        if calendar.component(.day, from: start) == 1,
           let monthLater = calendar.date(byAdding: .month, value: 1, to: start),
           abs(monthLater.timeIntervalSince(interval.end)) < 3600,
           let previousStart = calendar.date(byAdding: .month, value: -1, to: start) {
            return DateInterval(start: previousStart, end: start)
        }
        return DateInterval(start: start.addingTimeInterval(-interval.duration), end: start)
    }

    static func snapshot(_ input: Input, interval: DateInterval, now: Date = Date(),
                         calendar: Calendar = .current) -> Snapshot {
        let previousInterval = previous(of: interval, calendar: calendar)
        let current = clip(input.entries, to: interval)
        let before = clip(input.entries, to: previousInterval)

        let summary = makeSummary(current, before, input: input, interval: interval,
                                  previousInterval: previousInterval, calendar: calendar)
        return Snapshot(
            interval: interval,
            previousInterval: previousInterval,
            summary: summary,
            days: perDay(current, calendar: calendar),
            heatmap: heatmap(current, calendar: calendar),
            focus: makeFocus(current, samples: input.samples, idle: input.idleSeconds, interval: interval,
                             calendar: calendar),
            meetings: makeMeetings(input, interval: interval, tracked: summary.tracked.current),
            quality: makeQuality(current, input: input, interval: interval),
            colorKeys: Array(Set(current.map { $0.projectID?.uuidString ?? "none" })).sorted(),
            entries: current,
            previousEntries: before
        )
    }

    // MARK: - Pieces

    /// Entries cut to the interval; ones entirely outside are dropped.
    static func clip(_ entries: [EntryFact], to interval: DateInterval) -> [EntryFact] {
        entries.compactMap { e in
            let start = max(e.start, interval.start), end = min(e.end, interval.end)
            guard end > start else { return nil }
            return EntryFact(id: e.id, title: e.title, start: start, end: end, projectID: e.projectID, projectName: e.projectName,
                             customerID: e.customerID, customerName: e.customerName, roleID: e.roleID,
                             roleName: e.roleName, billable: e.billable, source: e.source,
                             humanConfirmed: e.humanConfirmed, todoTitle: e.todoTitle)
        }
    }

    private static func seconds(_ entries: [EntryFact]) -> TimeInterval {
        entries.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Calendar-started entries count as meetings.
    private static func isMeeting(_ e: EntryFact) -> Bool { e.source == .calendar }

    private static func workingDays(_ entries: [EntryFact], calendar: Calendar) -> Int {
        var perDay: [Date: TimeInterval] = [:]
        for e in entries { perDay[calendar.startOfDay(for: e.start), default: 0] += e.end.timeIntervalSince(e.start) }
        return perDay.values.filter { $0 >= 15 * 60 }.count
    }

    private static func makeSummary(_ current: [EntryFact], _ before: [EntryFact], input: Input,
                                    interval: DateInterval, previousInterval: DateInterval,
                                    calendar: Calendar) -> Summary {
        let tracked = seconds(current), trackedBefore = seconds(before)
        let billable = seconds(current.filter(\.billable)), billableBefore = seconds(before.filter(\.billable))
        let days = workingDays(current, calendar: calendar), daysBefore = workingDays(before, calendar: calendar)
        let meeting = meetingTime(input, in: interval).seconds
        let meetingBefore = meetingTime(input, in: previousInterval).seconds
        return Summary(
            tracked: Delta(current: tracked, previous: trackedBefore),
            billable: Delta(current: billable, previous: billableBefore),
            billableShare: Delta(current: tracked > 0 ? billable / tracked : 0,
                                 previous: trackedBefore > 0 ? billableBefore / trackedBefore : 0),
            perWorkingDay: Delta(current: days > 0 ? tracked / Double(days) : 0,
                                 previous: daysBefore > 0 ? trackedBefore / Double(daysBefore) : 0),
            workingDays: days,
            meetingSeconds: Delta(current: meeting, previous: meetingBefore),
            entryCount: current.count,
            averageEntry: current.isEmpty ? 0 : tracked / Double(current.count)
        )
    }

    /// Per day and project, splitting entries that cross midnight.
    static func perDay(_ entries: [EntryFact], calendar: Calendar) -> [DaySlice] {
        var totals: [Date: [String: (name: String, seconds: TimeInterval)]] = [:]
        for e in entries {
            var cursor = e.start
            while cursor < e.end {
                let dayStart = calendar.startOfDay(for: cursor)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? e.end
                let pieceEnd = min(e.end, dayEnd)
                let key = e.projectID?.uuidString ?? "none"
                var bucket = totals[dayStart, default: [:]]
                bucket[key, default: (e.projectName ?? "No project", 0)].seconds += pieceEnd.timeIntervalSince(cursor)
                totals[dayStart] = bucket
                cursor = pieceEnd
            }
        }
        var slices: [DaySlice] = []
        for (day, byKey) in totals {
            for (key, value) in byKey {
                slices.append(DaySlice(day: day, key: key, name: value.name, seconds: value.seconds))
            }
        }
        slices.sort { lhs, rhs in
            lhs.day == rhs.day ? lhs.name < rhs.name : lhs.day < rhs.day
        }
        return slices
    }

    /// Time per weekday and hour of day.
    static func heatmap(_ entries: [EntryFact], calendar: Calendar) -> [HeatCell] {
        var cells: [Int: TimeInterval] = [:]
        for e in entries {
            var cursor = e.start
            while cursor < e.end {
                let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
                let hourEnd = hourStart.addingTimeInterval(3600)
                let pieceEnd = min(e.end, hourEnd)
                let weekday = (calendar.component(.weekday, from: cursor) + 5) % 7 + 1   // Monday = 1
                let hour = calendar.component(.hour, from: cursor)
                cells[weekday * 100 + hour, default: 0] += pieceEnd.timeIntervalSince(cursor)
                cursor = pieceEnd
            }
        }
        return cells.map { HeatCell(weekday: $0.key / 100, hour: $0.key % 100, seconds: $0.value) }
            .sorted { $0.id < $1.id }
    }

    static func breakdown(_ entries: [EntryFact], previous: [EntryFact], interval: DateInterval,
                          previousInterval: DateInterval, by dimension: Dimension) -> [BreakdownLine] {
        func key(_ e: EntryFact) -> (String, String) {
            switch dimension {
            case .project: return (e.projectID?.uuidString ?? "none", e.projectName ?? "No project")
            case .customer: return (e.customerID?.uuidString ?? "none", e.customerName ?? "No customer")
            case .role: return (e.roleID?.uuidString ?? "none", e.roleName ?? "No role")
            }
        }
        var current: [String: (name: String, total: TimeInterval, billable: TimeInterval)] = [:]
        for e in entries {
            let (k, name) = key(e)
            let s = e.end.timeIntervalSince(e.start)
            current[k, default: (name, 0, 0)].total += s
            if e.billable { current[k, default: (name, 0, 0)].billable += s }
        }
        var before: [String: TimeInterval] = [:]
        for e in previous { before[key(e).0, default: 0] += e.end.timeIntervalSince(e.start) }
        let total = current.values.reduce(0) { $0 + $1.total }
        return current.map { k, v in
            BreakdownLine(key: k, name: v.name, seconds: v.total, billableSeconds: v.billable,
                          previousSeconds: before[k] ?? 0, share: total > 0 ? v.total / total : 0)
        }
        .sorted { $0.seconds > $1.seconds }
    }

    /// Chat, mail and call apps.
    static let communicationApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.microsoft.Outlook",
        "com.apple.mail", "us.zoom.xos", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
        "com.hnc.Discord", "com.apple.FaceTime", "ru.keepcoder.Telegram",
    ]

    /// Largest first; ties by name so the order is stable.
    private static func ranked(_ totals: [String: TimeInterval]) -> [Ranked] {
        totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { Ranked(name: $0.key, seconds: $0.value) }
    }

    /// A real site: has a domain, not a local file or a browser page like "newtab".
    static func isWebsite(_ host: String) -> Bool {
        host.contains(".") && !host.hasPrefix("file:") && !host.contains(" ")
    }

    private static func makeFocus(_ entries: [EntryFact], samples: [SampleFact],
                                  idle: [(start: Date, end: Date)], interval: DateInterval,
                                  calendar: Calendar) -> Focus {
        let inRange = samples.filter { interval.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        var apps: [String: TimeInterval] = [:], hosts: [String: TimeInterval] = [:]
        var communication: TimeInterval = 0, observed: TimeInterval = 0, switches = 0
        for (i, s) in inRange.enumerated() {
            // A sample stands for the time until the next, capped so gaps don't count.
            let next = i + 1 < inRange.count ? inRange[i + 1].timestamp : s.timestamp.addingTimeInterval(30)
            let weight = min(max(0, next.timeIntervalSince(s.timestamp)), 90)
            apps[s.appName, default: 0] += weight
            if let host = s.host, isWebsite(host) { hosts[host, default: 0] += weight }
            if communicationApps.contains(s.bundleId) { communication += weight }
            observed += weight
            if i > 0, inRange[i - 1].bundleId != s.bundleId { switches += 1 }
        }
        // Away only counts inside each day's working span (first to last activity),
        // so nights and weekends don't swamp it.
        var spans: [Date: (start: Date, end: Date)] = [:]
        for s in inRange {
            let day = calendar.startOfDay(for: s.timestamp)
            let span = spans[day] ?? (s.timestamp, s.timestamp)
            spans[day] = (min(span.start, s.timestamp), max(span.end, s.timestamp))
        }
        var away: TimeInterval = 0
        for span in idle {
            for day in spans.values {
                let start = max(span.start, day.start), end = min(span.end, day.end)
                away += max(0, end.timeIntervalSince(start))
            }
        }
        let lengths = entries.map { $0.end.timeIntervalSince($0.start) }
        return Focus(
            topApps: Array(ranked(apps).prefix(8)),
            topSites: Array(ranked(hosts).prefix(8)),
            communicationShare: observed > 0 ? communication / observed : 0,
            switchesPerHour: observed > 0 ? Double(switches) / (observed / 3600) : 0,
            longBlocks: lengths.filter { $0 >= 45 * 60 }.count,
            longestBlock: lengths.max() ?? 0,
            observedSeconds: observed,
            awaySeconds: away
        )
    }

    /// Recorded meetings plus calendar entries no recording covers: a recorded meeting
    /// usually also has a calendar entry, and its time counts once.
    private static func meetingTime(_ input: Input, in interval: DateInterval)
        -> (seconds: TimeInterval, recorded: [MeetingFact], uncovered: [EntryFact]) {
        let calendarEntries = clip(input.entries, to: interval).filter(isMeeting)
        let recorded = input.meetings.filter { interval.contains($0.start) }
        let uncovered = calendarEntries.filter { e in
            !recorded.contains { $0.start < e.end && e.start < $0.end }
        }
        let recordedSeconds = recorded.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return (recordedSeconds + seconds(uncovered), recorded, uncovered)
    }

    private static func makeMeetings(_ input: Input, interval: DateInterval, tracked: TimeInterval) -> Meetings {
        let (total, recorded, uncovered) = meetingTime(input, in: interval)
        let recordedIDs = Set(recorded.map(\.id))
        let count = recorded.count + uncovered.count

        let speakers = input.speakers.filter { recordedIDs.contains($0.meetingID) }
        let speech = speakers.reduce(0.0) { $0 + $1.seconds }
        let mine = speakers.filter(\.isMe).reduce(0.0) { $0 + $1.seconds }
        var people: [String: (seconds: Double, meetings: Set<UUID>)] = [:]
        for s in speakers where !s.isMe {
            let name = s.personName ?? "Unnamed voices"
            people[name, default: (0, [])].seconds += s.seconds
            people[name, default: (0, [])].meetings.insert(s.meetingID)
        }
        let proposals = input.proposals.filter { interval.contains($0.createdAt) }
        var longest: [Ranked] = recorded.map { meeting in
            Ranked(name: meeting.title, seconds: meeting.end.timeIntervalSince(meeting.start))
        }
        for entry in uncovered where !entry.title.isEmpty {
            longest.append(Ranked(name: entry.title, seconds: entry.end.timeIntervalSince(entry.start)))
        }
        longest.sort { $0.seconds > $1.seconds }
        return Meetings(
            count: count,
            seconds: total,
            averageLength: count > 0 ? total / Double(count) : 0,
            shareOfTracked: tracked > 0 ? min(1, total / tracked) : 0,
            myTalkShare: speech > 0 && speakers.contains(where: \.isMe) ? mine / speech : nil,
            people: people.sorted { $0.value.seconds > $1.value.seconds }.prefix(8).map {
                Ranked(name: $0.key, seconds: $0.value.seconds,
                       detail: "\($0.value.meetings.count) meeting\($0.value.meetings.count == 1 ? "" : "s")")
            },
            longest: Array(longest.prefix(5)),
            proposalsAccepted: proposals.filter { $0.status == .accepted }.count,
            proposalsDeclined: proposals.filter { $0.status == .declined }.count,
            proposalsPending: proposals.filter { $0.status == .pending }.count
        )
    }

    private static func makeQuality(_ entries: [EntryFact], input: Input, interval: DateInterval) -> Quality {
        let tracked = seconds(entries)
        let unassigned = seconds(entries.filter { $0.projectID == nil })
        let reviewed = seconds(entries.filter(\.humanConfirmed))
        var bySource: [String: TimeInterval] = [:]
        for e in entries {
            let label: String
            switch e.source {
            case .manual: label = "Started by you"
            case .calendar: label = "From the calendar"
            case .aiAutoStart: label = "Started by AI"
            case .aiSwitch: label = "AI task switch"
            case .userCorrected: label = "Corrected switch"
            }
            bySource[label, default: 0] += e.end.timeIntervalSince(e.start)
        }
        let decisions = input.decisions.filter { interval.contains($0.at) }
        let asked = decisions.filter { $0.kind == .asked }
        return Quality(
            unassignedShare: tracked > 0 ? unassigned / tracked : 0,
            unassignedSeconds: unassigned,
            reviewedShare: tracked > 0 ? reviewed / tracked : 0,
            bySource: ranked(bySource),
            questionsAsked: asked.count,
            questionsAccepted: asked.filter { $0.response == .switched || $0.response == .switchedEdited }.count,
            questionsRejected: asked.filter { $0.response == .keptCurrent }.count,
            questionsIgnored: asked.filter { $0.response == .timedOut || $0.response == .dismissed || $0.response == nil }.count,
            automaticSwitches: decisions.filter { $0.kind == .autoSwitched }.count,
            todosCompleted: input.todosCompleted.filter { interval.contains($0) }.count
        )
    }
}
