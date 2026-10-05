import Foundation

/// Vector similarity over sparse weight maps. Pure arithmetic, no dependencies.
enum Similarity {

    /// Cosine similarity of two sparse vectors. Returns 1 when both are empty —
    /// "nothing changed" is the right reading of "no evidence on either side".
    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        var dot = 0.0
        // Iterate the smaller map; the dot product is symmetric.
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        for (key, value) in small {
            if let other = large[key] { dot += value * other }
        }
        let magA = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let magB = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        guard magA > 0, magB > 0 else { return 0 }
        return clamp01(dot / (magA * magB))
    }

    /// Weighted Jaccard: `Σ min(a,b) / Σ max(a,b)`.
    ///
    /// Preferred over cosine for title tokens, which are sparse and long-tailed:
    /// this penalises *added* vocabulary as much as removed, which is what we want
    /// when a new project's jargon appears mid-window.
    static func weightedJaccard(_ a: [String: Double], _ b: [String: Double]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        var minSum = 0.0
        var maxSum = 0.0
        for key in Set(a.keys).union(b.keys) {
            let x = a[key] ?? 0
            let y = b[key] ?? 0
            minSum += Swift.min(x, y)
            maxSum += Swift.max(x, y)
        }
        guard maxSum > 0 else { return 1 }
        return clamp01(minSum / maxSum)
    }

    /// Scales a weight map so its values sum to 1. Empty stays empty.
    static func normalized(_ v: [String: Double]) -> [String: Double] {
        let total = v.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return v.mapValues { $0 / total }
    }

    static func clamp01(_ x: Double) -> Double { Swift.min(1, Swift.max(0, x)) }
}
