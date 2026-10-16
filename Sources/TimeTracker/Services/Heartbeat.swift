import Foundation

/// When the app was last known to be running, kept across launches. A crash, a forced
/// quit or a power cut leaves no other trace, and without it the time the app was not
/// watching would be counted as work on whatever was running.
@MainActor
final class Heartbeat {
    private let defaults: UserDefaults
    private let key = "heartbeat.lastAliveAt"
    /// How often the beat is written; the last-known moment is at most this stale.
    private let interval: TimeInterval
    private var lastWritten: Date?

    init(defaults: UserDefaults = .standard, interval: TimeInterval = 30) {
        self.defaults = defaults
        self.interval = interval
    }

    var lastAliveAt: Date? { defaults.object(forKey: key) as? Date }

    func beat(now: Date = Date(), force: Bool = false) {
        if !force, let lastWritten, now.timeIntervalSince(lastWritten) < interval { return }
        defaults.set(now, forKey: key)
        lastWritten = now
    }
}
