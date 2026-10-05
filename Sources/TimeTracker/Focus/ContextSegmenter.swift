import Foundation

/// Finds instants where the user's working context plausibly changed.
///
/// Nothing in the app did this before: activity samples were collected every 30 s and
/// never segmented, so the only task boundaries the tracker could ever see came from
/// going idle or from the calendar. This is the missing piece.
///
/// Two design choices drive everything:
///
/// 1. **Time-weighted profiles.** `ActivityMonitor` samples on a 30 s timer *and* on
///    every app activation, so a flurry of app switches produces a flurry of rows.
///    Counting rows would let three 2-second glances at Slack outweigh five minutes of
///    real work. Every sample is weighted by how long it was actually on screen.
///
/// 2. **Deliberate lag.** A boundary is only real if the new context *persists*.
///    "Glanced at Slack for 40 s" and "switched projects" are indistinguishable at t+0
///    and obvious at t+3min, so the segmenter asks "was there a boundary ~2 minutes
///    ago?" and marks anything more recent `isProvisional`. This is why boundaries are
///    retroactive by construction — which is exactly what is needed to close the
///    previous entry at the moment the change really happened.
enum ContextSegmenter {

    // MARK: - Configuration

    struct Config: Equatable, Sendable {
        /// Half-width of the comparison windows either side of a candidate instant.
        var windowSeconds: TimeInterval = 300
        /// How long the new context must persist before a candidate is actionable.
        var dwellSeconds: TimeInterval = 120
        /// The two halves of the dwell window must diverge by less than this for the
        /// new context to count as settled rather than a passing interruption.
        var dwellStabilityMax: Double = 0.35
        /// Winning candidates suppress others within this radius.
        var suppressionSeconds: TimeInterval = 300
        /// Below this, no candidate is emitted at all.
        var candidateThreshold: Double = 0.45
        /// At or above this, the arbiter may act without waiting for more evidence.
        var hardThreshold: Double = 0.75
        /// A sample never counts for more than this much wall time, so a long gap
        /// between samples does not inflate one app's share.
        var maxSampleGapSeconds: TimeInterval = 90
        /// How far back to look for candidate instants.
        var lookbackSeconds: TimeInterval = 40 * 60
        /// A window holding less than this much wall time can't support a judgement.
        var thinWindowSeconds: TimeInterval = 60
        /// Learned suppressions: `"beforeBundleId>afterBundleId"` pairs the user has
        /// repeatedly rejected. Populated from the decision log.
        var suppressedTransitions: Set<String> = []

        static let `default` = Config()
    }

    // MARK: - Input / Output

    struct Input {
        let now: Date
        /// Ascending by timestamp.
        let samples: [SignalSample]
        let idleSpans: [IdleSpan]
        let meetings: [MeetingWindow]
        let currentEntry: EntryContext?
        let allowedCalendarIds: Set<String>?
        let config: Config

        init(
            now: Date,
            samples: [SignalSample],
            idleSpans: [IdleSpan] = [],
            meetings: [MeetingWindow] = [],
            currentEntry: EntryContext? = nil,
            allowedCalendarIds: Set<String>? = nil,
            config: Config = .default
        ) {
            self.now = now
            self.samples = samples
            self.idleSpans = idleSpans
            self.meetings = meetings
            self.currentEntry = currentEntry
            self.allowedCalendarIds = allowedCalendarIds
            self.config = config
        }
    }

    struct Output: Equatable {
        /// Score-descending, after non-maximum suppression.
        let candidates: [BoundaryCandidate]
        /// The most recent window, for evidence and logging.
        let currentProfile: WindowProfile
    }

    /// Time-weighted description of what the user was doing over an interval.
    struct WindowProfile: Equatable, Sendable {
        let start: Date
        let end: Date
        let totalWeight: TimeInterval
        let apps: [String: Double]
        let tokens: [String: Double]
        let hosts: [String: Double]
        /// Share of the window's weight that carried call evidence, 0...1.
        let callShare: Double

        var topApp: String? { apps.max { $0.value < $1.value }?.key }
        func isThin(_ config: Config) -> Bool { totalWeight < config.thinWindowSeconds }

        static let empty = WindowProfile(
            start: .distantPast, end: .distantPast, totalWeight: 0,
            apps: [:], tokens: [:], hosts: [:], callShare: 0
        )
    }

    struct BoundaryCandidate: Equatable, Sendable {
        let at: Date
        let score: Double
        let reasons: [BoundaryReason]
        let before: WindowProfile
        let after: WindowProfile
        /// The new context has not yet persisted long enough to be trusted.
        let isProvisional: Bool
        /// Strong enough to act on immediately (corroborated meeting, or a very high score).
        let isHard: Bool
        /// Present when the candidate came from a calendar event.
        let meetingEventId: String?

        var topTransition: String? {
            guard let b = before.topApp, let a = after.topApp else { return nil }
            return "\(b)>\(a)"
        }
    }

    // MARK: - Entry point

    static func evaluate(_ input: Input) -> Output {
        let config = input.config
        let prepared = prepare(input.samples)
        let currentProfile = profile(
            prepared,
            from: input.now.addingTimeInterval(-config.windowSeconds),
            to: input.now,
            config: config
        )
        guard !prepared.isEmpty || !input.meetings.isEmpty else {
            return Output(candidates: [], currentProfile: currentProfile)
        }

        var candidates: [BoundaryCandidate] = []
        for instant in candidateInstants(input) {
            if let candidate = score(at: instant, prepared: prepared, input: input) {
                candidates.append(candidate)
            }
        }
        return Output(
            candidates: suppressNonMaxima(candidates, config: config),
            currentProfile: currentProfile
        )
    }

    // MARK: - Candidate instants

    /// A boundary can only sit where something observable happened: an app switch, the
    /// end of an idle span, or a meeting edge. Scoring every second would be waste.
    private static func candidateInstants(_ input: Input) -> [Date] {
        let config = input.config
        let earliest = input.now.addingTimeInterval(-config.lookbackSeconds)
        var instants: Set<Date> = []

        var previousBundle: String?
        for sample in input.samples where sample.timestamp >= earliest {
            if let previous = previousBundle, previous != sample.bundleId {
                instants.insert(sample.timestamp)
            }
            previousBundle = sample.bundleId
        }
        for idle in input.idleSpans {
            if let end = idle.end, end >= earliest { instants.insert(end) }
        }
        for meeting in input.meetings {
            if meeting.start >= earliest && meeting.start <= input.now { instants.insert(meeting.start) }
            if meeting.end >= earliest && meeting.end <= input.now { instants.insert(meeting.end) }
        }

        // Never propose a boundary before the current entry even began, plus the
        // minimum segment length — a sliver is worse than no split at all.
        let floor = input.currentEntry.map { $0.startAt.addingTimeInterval(180) }
        return instants
            .filter { instant in floor.map { instant >= $0 } ?? true }
            .sorted()
    }

    // MARK: - Scoring

    private static func score(
        at instant: Date,
        prepared: [PreparedSample],
        input: Input
    ) -> BoundaryCandidate? {
        let config = input.config

        // Idle: only meaningful at the *end* of a gap — that is when work resumes, and
        // the longer the gap the more likely it resumed as something else.
        var idleBoost = 0.0
        var precedingIdle: IdleSpan?
        for idle in input.idleSpans {
            guard let end = idle.end else { continue }
            guard abs(end.timeIntervalSince(instant)) <= 60 else { continue }
            let gap = end.timeIntervalSince(idle.start)
            let boost = 0.30 * min(1, gap / 900)
            if boost > idleBoost {
                idleBoost = boost
                precedingIdle = idle
            }
        }

        // When the boundary sits at the end of an idle gap, the window immediately
        // before it is empty by definition — the user was away. Comparing against
        // nothing would make the most informative case (returning from lunch to a
        // different task) score lowest. Anchor the "before" window to the last activity
        // prior to the gap instead: "what I was doing before I left" vs "what I'm doing
        // now" is the comparison that actually matters here.
        let beforeAnchor = precedingIdle?.start ?? instant
        let before = profile(
            prepared,
            from: beforeAnchor.addingTimeInterval(-config.windowSeconds),
            to: beforeAnchor,
            config: config
        )
        let after = profile(
            prepared,
            from: instant,
            to: instant.addingTimeInterval(config.windowSeconds),
            config: config
        )

        var reasons: [BoundaryReason] = []
        if idleBoost > 0 { reasons.append(.idleGap) }

        // Activity divergence. With too little data on either side we cannot judge the
        // activity at all, so we contribute nothing and let the discrete boosts decide.
        var divergence = 0.0
        if !before.isThin(config) && !after.isThin(config) {
            let parts = divergenceParts(before: before, after: after)
            divergence = parts.value
            reasons.append(contentsOf: parts.reasons)
        }

        // Meetings.
        var meetingBoost = 0.0
        var meetingEventId: String?
        var meetingCorroborated = false
        for meeting in input.meetings {
            let isStart = abs(meeting.start.timeIntervalSince(instant)) <= 60
            let isEnd = abs(meeting.end.timeIntervalSince(instant)) <= 60
            guard isStart || isEnd else { continue }
            let overlaps = titleOverlapsActivity(meeting.title, profile: isStart ? after : before)
            let weight = AttendanceFilter.weight(
                for: meeting,
                callShareAfter: isStart ? after.callShare : before.callShare,
                allowedCalendarIds: input.allowedCalendarIds,
                titleOverlapsActivity: overlaps
            )
            guard weight > 0 else { continue }
            let boost = 0.45 * weight
            if boost > meetingBoost {
                meetingBoost = boost
                meetingEventId = meeting.eventId
                meetingCorroborated = AttendanceFilter.isCorroborated(
                    callShareAfter: isStart ? after.callShare : before.callShare
                )
                let reason: BoundaryReason = isStart ? .meetingStart : .meetingEnd
                if !reasons.contains(reason) { reasons.append(reason) }
            }
        }

        let score = Similarity.clamp01(0.70 * divergence + idleBoost + meetingBoost)
        guard score >= config.candidateThreshold else { return nil }

        // Learned suppression: transitions the user keeps rejecting.
        if let transition = transitionKey(before: before, after: after),
           config.suppressedTransitions.contains(transition) {
            return nil
        }

        // Persistence gate. If the second half of the dwell window looks nothing like
        // the first, the "new context" is a passing interruption, not a new task.
        let elapsedSinceInstant = input.now.timeIntervalSince(instant)
        var isProvisional = elapsedSinceInstant < config.dwellSeconds
        if !isProvisional {
            let half = config.dwellSeconds / 2
            let firstHalf = profile(prepared, from: instant, to: instant.addingTimeInterval(half), config: config)
            let secondHalf = profile(
                prepared,
                from: instant.addingTimeInterval(half),
                to: instant.addingTimeInterval(config.dwellSeconds),
                config: config
            )
            if !firstHalf.isThin(config) && !secondHalf.isThin(config) {
                let churn = divergenceParts(before: firstHalf, after: secondHalf).value
                if churn >= config.dwellStabilityMax { return nil }
            } else {
                // Not enough data yet to confirm the context settled.
                isProvisional = true
            }
        }

        return BoundaryCandidate(
            at: instant,
            score: score,
            reasons: orderedReasons(reasons, before: before, after: after),
            before: before,
            after: after,
            isProvisional: isProvisional,
            isHard: meetingCorroborated || score >= config.hardThreshold,
            meetingEventId: meetingEventId
        )
    }

    /// The four component deltas, combined with their weights. When URLs are absent on
    /// both sides the host term is dropped and its weight redistributed over the rest,
    /// so native-app work is not scored as if a signal were missing.
    private static func divergenceParts(
        before: WindowProfile,
        after: WindowProfile
    ) -> (value: Double, reasons: [BoundaryReason]) {
        let appDelta = 1 - Similarity.cosine(before.apps, after.apps)
        let topicDelta = 1 - Similarity.weightedJaccard(before.tokens, after.tokens)
        let mediaDelta = abs(before.callShare - after.callShare)

        var terms: [(delta: Double, weight: Double)] = [
            (appDelta, 0.35),
            (topicDelta, 0.30),
            (mediaDelta, 0.15),
        ]
        var hostDelta: Double?
        if !(before.hosts.isEmpty && after.hosts.isEmpty) {
            let delta = 1 - Similarity.cosine(before.hosts, after.hosts)
            hostDelta = delta
            terms.append((delta, 0.20))
        }

        let totalWeight = terms.reduce(0) { $0 + $1.weight }
        let value = totalWeight > 0
            ? terms.reduce(0) { $0 + $1.delta * $1.weight } / totalWeight
            : 0

        var reasons: [BoundaryReason] = []
        if appDelta > 0.5 { reasons.append(.appSwitch) }
        if topicDelta > 0.5 { reasons.append(.topicShift) }
        if let hostDelta, hostDelta > 0.5 { reasons.append(.hostChange) }
        if mediaDelta > 0.5 { reasons.append(.mediaChange) }
        return (Similarity.clamp01(value), reasons)
    }

    private static func orderedReasons(
        _ reasons: [BoundaryReason],
        before: WindowProfile,
        after: WindowProfile
    ) -> [BoundaryReason] {
        // Stable, meaningful order: discrete events first, then activity deltas.
        let priority: [BoundaryReason] = [
            .meetingStart, .meetingEnd, .idleGap,
            .mediaChange, .topicShift, .hostChange, .appSwitch,
        ]
        return priority.filter(reasons.contains)
    }

    private static func transitionKey(before: WindowProfile, after: WindowProfile) -> String? {
        guard let b = before.topApp, let a = after.topApp else { return nil }
        return "\(b)>\(a)"
    }

    private static func titleOverlapsActivity(_ title: String, profile: WindowProfile) -> Bool {
        let titleTokens = Set(TitleTokenizer.tokens(from: title))
        guard !titleTokens.isEmpty, !profile.tokens.isEmpty else { return false }
        return !titleTokens.isDisjoint(with: Set(profile.tokens.keys))
    }

    // MARK: - Non-maximum suppression

    private static func suppressNonMaxima(
        _ candidates: [BoundaryCandidate],
        config: Config
    ) -> [BoundaryCandidate] {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.at > rhs.at        // ties: prefer the more recent instant
        }
        var kept: [BoundaryCandidate] = []
        for candidate in sorted {
            let clashes = kept.contains {
                abs($0.at.timeIntervalSince(candidate.at)) < config.suppressionSeconds
            }
            if !clashes { kept.append(candidate) }
        }
        return kept
    }

    // MARK: - Profiles

    /// Tokenising once per sample instead of once per (sample, candidate) pair keeps a
    /// full evaluation in the microsecond range, so it can run on every 30 s tick.
    private struct PreparedSample {
        let timestamp: Date
        let bundleId: String
        let tokens: [String]
        let hostKey: String?
        let inCall: Bool
    }

    private static func prepare(_ samples: [SignalSample]) -> [PreparedSample] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map {
                PreparedSample(
                    timestamp: $0.timestamp,
                    bundleId: $0.bundleId,
                    tokens: TitleTokenizer.tokens(from: $0.windowTitle),
                    hostKey: TitleTokenizer.hostKey(from: $0.url),
                    inCall: $0.flags.inCall
                )
            }
    }

    private static func profile(
        _ prepared: [PreparedSample],
        from: Date,
        to: Date,
        config: Config
    ) -> WindowProfile {
        var apps: [String: Double] = [:]
        var tokens: [String: Double] = [:]
        var hosts: [String: Double] = [:]
        var callWeight = 0.0
        var total = 0.0

        for (index, sample) in prepared.enumerated() {
            // A sample owns the wall time until the next one, capped so a long gap
            // (lunch, a meeting away from the desk) doesn't inflate its share.
            let nextTimestamp = index + 1 < prepared.count
                ? prepared[index + 1].timestamp
                : sample.timestamp.addingTimeInterval(config.maxSampleGapSeconds)
            let spanEnd = min(
                nextTimestamp,
                sample.timestamp.addingTimeInterval(config.maxSampleGapSeconds)
            )
            let lo = max(sample.timestamp, from)
            let hi = min(spanEnd, to)
            let weight = hi.timeIntervalSince(lo)
            guard weight > 0 else { continue }

            apps[sample.bundleId, default: 0] += weight
            for token in sample.tokens { tokens[token, default: 0] += weight }
            if let host = sample.hostKey { hosts[host, default: 0] += weight }
            if sample.inCall { callWeight += weight }
            total += weight
        }

        return WindowProfile(
            start: from,
            end: to,
            totalWeight: total,
            apps: Similarity.normalized(apps),
            tokens: Similarity.normalized(tokens),
            hosts: Similarity.normalized(hosts),
            callShare: total > 0 ? callWeight / total : 0
        )
    }
}
