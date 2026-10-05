import Foundation

/// Decides *how* to apply a task boundary to the timeline, before anything is written.
///
/// Splitting a running entry retroactively is the operation most able to corrupt a
/// day's data: a boundary before the entry started yields a negative duration, one a
/// few seconds after it yields a useless sliver, and a boundary in the future yields an
/// entry that has not happened yet. Keeping the decision pure means those invariants
/// are unit-testable instead of being hoped for inside a SwiftData mutation.
enum TimelineGuard {

    struct Segment: Equatable, Sendable {
        let id: UUID
        let start: Date
        let end: Date?

        init(id: UUID, start: Date, end: Date? = nil) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    struct Config: Equatable, Sendable {
        /// No entry may be created shorter than this. An over-eager arbiter that
        /// shreds a day into 40 fragments destroys trust irrecoverably, so this is a
        /// safety net rather than a nicety.
        var minSegmentSeconds: TimeInterval = 180
        /// Cap on how far back a fresh start may be back-dated when nothing is running.
        var maxBackdateSeconds: TimeInterval = 3600

        static let `default` = Config()
    }

    enum Plan: Equatable, Sendable {
        /// Close the current entry and open the next one at the *same* instant, so the
        /// two meet exactly — gap-free adjacency is an invariant, not an aspiration.
        case openNew(closeCurrentAt: Date, startNextAt: Date)
        /// The running entry is too young to split. Rewrite its fields instead of
        /// leaving a 40-second orphan beside a 20-second one.
        case correctInPlace
        case startFresh(at: Date)
        case reject(String)
    }

    /// - Parameter previousEnd: when the most recent closed entry ended. A fresh start
    ///   is never back-dated before it, so answering a question late cannot create an
    ///   entry that overlaps one the user already stopped.
    static func plan(
        current: Segment?,
        boundaryAt: Date,
        now: Date,
        previousEnd: Date? = nil,
        config: Config = .default
    ) -> Plan {
        // Never schedule a boundary in the future.
        var boundary = min(boundaryAt, now)

        guard let current else {
            var earliest = now.addingTimeInterval(-config.maxBackdateSeconds)
            if let previousEnd { earliest = max(earliest, min(previousEnd, now)) }
            return .startFresh(at: max(boundary, earliest))
        }

        if current.end != nil {
            return .reject("current segment is already closed")
        }

        // Too young to split at all: whatever the boundary says, cutting here would
        // produce a fragment. Correct the entry we already have.
        if now.timeIntervalSince(current.start) < config.minSegmentSeconds {
            return .correctInPlace
        }

        // Never carve a sliver off the front of the running entry. Safe to push
        // forward: the check above guarantees this stays at or before `now`.
        boundary = max(boundary, current.start.addingTimeInterval(config.minSegmentSeconds))

        guard boundary > current.start else {
            return .reject("boundary is not after the current segment start")
        }
        guard boundary <= now else {
            return .reject("boundary is in the future")
        }

        return .openNew(closeCurrentAt: boundary, startNextAt: boundary)
    }
}
