import Foundation

/// Who spoke when in one audio track: segments labelled with a cluster id, and one
/// voice embedding per cluster.
struct DiarizationOutput: Equatable, Sendable {
    struct Segment: Equatable, Sendable, Codable {
        let start: Double
        let end: Double
        let cluster: String
    }

    let segments: [Segment]
    let embeddings: [String: [Float]]

    func speechSeconds(of cluster: String) -> Double {
        segments.filter { $0.cluster == cluster }.reduce(0) { $0 + ($1.end - $1.start) }
    }
}

/// Splits an audio file into speakers. Behind a protocol so the pipeline is testable
/// without models, audio, or the Neural Engine.
protocol Diarizer: Sendable {
    func diarize(_ url: URL) async throws -> DiarizationOutput
}
