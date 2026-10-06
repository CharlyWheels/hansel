import Foundation

/// Hard ceiling on how often the model may be consulted.
///
/// The point of the deterministic segmenter is that the expensive call happens only at
/// a plausible boundary. Without an explicit cap that intent quietly erodes, so this
/// makes the ~10-30 calls/day target a guarantee rather than a hope. When the budget is
/// spent the arbiter degrades to a label-free question instead of going silent —
/// asking "did you switch at 10:42?" without a proposed answer still beats losing the
/// boundary entirely.
struct LLMBudget: Equatable, Sendable {
    var maxPerHour: Int = 6
    var maxPerDay: Int = 30
    /// Two consultations may never be closer together than this.
    var minimumSpacingSeconds: TimeInterval = 180
    /// Calls held back for hard boundaries (meetings, cold starts), which must not be
    /// starved by a chatty afternoon of ordinary app switching.
    var reservedForHardBoundaries: Int = 6

    private(set) var timestamps: [Date] = []

    init(
        maxPerHour: Int = 6,
        maxPerDay: Int = 30,
        minimumSpacingSeconds: TimeInterval = 180,
        reservedForHardBoundaries: Int = 6
    ) {
        self.maxPerHour = maxPerHour
        self.maxPerDay = maxPerDay
        self.minimumSpacingSeconds = minimumSpacingSeconds
        self.reservedForHardBoundaries = reservedForHardBoundaries
    }

    /// Why a call is not allowed right now.
    enum Denial: Equatable, Sendable {
        /// Too soon after the previous call. Transient: try again on a later tick.
        case spacing
        /// The hourly or daily allowance is used up.
        case exhausted
    }

    func denial(at now: Date, isHard: Bool) -> Denial? {
        if let last = timestamps.last,
           now.timeIntervalSince(last) < minimumSpacingSeconds {
            return .spacing
        }
        let inLastHour = timestamps.filter { now.timeIntervalSince($0) < 3600 }.count
        if inLastHour >= maxPerHour { return .exhausted }

        let today = timestamps.filter { now.timeIntervalSince($0) < 86_400 }.count
        // Soft boundaries stop short of the reserve so a hard one later still gets through.
        let ceiling = isHard ? maxPerDay : maxPerDay - reservedForHardBoundaries
        return today < ceiling ? nil : .exhausted
    }

    func allows(at now: Date, isHard: Bool) -> Bool {
        denial(at: now, isHard: isHard) == nil
    }

    mutating func consume(at now: Date, isHard: Bool) -> Bool {
        guard allows(at: now, isHard: isHard) else { return false }
        record(at: now)
        return true
    }

    /// Counts a call made elsewhere (the activity watchdog) against the same ceiling.
    mutating func record(at now: Date) {
        timestamps.append(now)
        timestamps.sort()
        prune(now: now)
    }

    // MARK: - Persistence
    //
    // An in-memory budget resets on every relaunch, so "at most N calls a day" was only
    // true per process. The timestamps are tiny; UserDefaults is enough.

    static let defaultsKey = "llmBudget.timestamps"

    /// `budget` carries the limits; only its timestamps are restored. A separate `key`
    /// gives a feature its own allowance (meeting tasks do not eat into task switches).
    static func loadPersisted(
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        key: String = defaultsKey,
        budget limits: LLMBudget = LLMBudget()
    ) -> LLMBudget {
        var budget = limits
        let raw = defaults.array(forKey: key) as? [Double] ?? []
        budget.timestamps = raw.map(Date.init(timeIntervalSince1970:)).sorted()
        budget.prune(now: now)
        return budget
    }

    func persist(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        defaults.set(timestamps.map(\.timeIntervalSince1970), forKey: key)
    }

    mutating func prune(now: Date) {
        timestamps.removeAll { now.timeIntervalSince($0) >= 86_400 }
    }

    func remainingToday(at now: Date) -> Int {
        max(0, maxPerDay - timestamps.filter { now.timeIntervalSince($0) < 86_400 }.count)
    }
}
