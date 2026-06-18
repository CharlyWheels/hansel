import Foundation

enum DurationFormat {
    /// "1h 23m" or "5m 12s" (for sub-hour) or "45s" (sub-minute).
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// "0:05:12" — for the running-timer chip.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    /// "1h 23m" without seconds — for entry summaries.
    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
