import Foundation

/// Voiceprint arithmetic and the rules for what counts as a voice. Pure, for tests.
enum SpeakerMatching {

    /// At or above: the same person, assigned without asking.
    static let recognisedThreshold: Double = 0.75
    /// At or above (and below `recognisedThreshold`): shown as a suggestion to confirm.
    static let suggestionThreshold: Double = 0.55

    /// A cluster with less speech than this is not treated as a person: on a real call
    /// the diarizer also finds notification chimes and echo bleeding between tracks.
    static let minimumSpeechSeconds: Double = 30
    static let minimumShareOfTrack: Double = 0.03

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        let denominator = na.squareRoot() * nb.squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    static func runningMean(_ mean: [Float], count: Int, adding sample: [Float]) -> [Float] {
        guard count > 0, mean.count == sample.count else { return sample }
        let n = Float(count)
        return zip(mean, sample).map { ($0 * n + $1) / (n + 1) }
    }

    /// Clusters worth showing as people: enough speech in absolute and relative terms.
    static func voices(in output: DiarizationOutput) -> [String] {
        let total = output.segments.reduce(0) { $0 + ($1.end - $1.start) }
        return Set(output.segments.map(\.cluster)).filter { cluster in
            let seconds = output.speechSeconds(of: cluster)
            return seconds >= minimumSpeechSeconds && (total == 0 || seconds / total >= minimumShareOfTrack)
        }.sorted()
    }

    struct Match: Equatable {
        let profileID: UUID
        let score: Double
        var isRecognised: Bool { score >= SpeakerMatching.recognisedThreshold }
    }

    /// The closest known voice, if it is close enough to at least suggest.
    static func bestMatch(for embedding: [Float], among profiles: [(id: UUID, embedding: [Float])]) -> Match? {
        let scored = profiles
            .filter { !$0.embedding.isEmpty }
            .map { Match(profileID: $0.id, score: cosine(embedding, $0.embedding)) }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score >= suggestionThreshold else { return nil }
        return best
    }
}

/// Who spoke at a given moment, from a meeting's diarised segments and the names given
/// to its speakers. Used for the transcript, the AI prompts and proposals.
struct SpeakerTimeline: Equatable {
    struct Segment: Equatable, Codable {
        let track: String
        let start: Double
        let end: Double
        let cluster: String
    }

    let segments: [Segment]
    /// "S2@system" → display name.
    let names: [String: String]

    init(segments: [Segment], names: [String: String]) {
        self.segments = segments.sorted { $0.start < $1.start }
        self.names = names
    }

    static func decode(_ data: Data?) -> [Segment] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Segment].self, from: data)) ?? []
    }

    static func encode(_ segments: [Segment]) -> Data? {
        try? JSONEncoder().encode(segments)
    }

    /// The cluster speaking in `track` between `start` and `end`: most overlap wins; with
    /// no overlap, the nearest segment within a second.
    func cluster(track: String, start: Double, end: Double?) -> String? {
        let stop = max(end ?? start + 1, start + 0.1)
        var overlap: [String: Double] = [:]
        var nearest: (cluster: String, distance: Double)?
        for s in segments where s.track == track {
            let o = min(s.end, stop) - max(s.start, start)
            if o > 0 { overlap[s.cluster, default: 0] += o; continue }
            let distance = o < 0 ? -o : 0
            if distance <= 1, distance < (nearest?.distance ?? .infinity) { nearest = (s.cluster, distance) }
        }
        return overlap.max(by: { $0.value < $1.value })?.key ?? nearest?.cluster
    }

    /// The name of whoever was speaking, if they have one.
    func name(track: String, start: Double, end: Double?) -> String? {
        cluster(track: track, start: start, end: end).flatMap { names["\($0)@\(track)"] }
    }

    /// Whoever was speaking at a moment, on whichever track had more speech around it.
    func name(at seconds: Double, window: Double = 2) -> String? {
        let start = seconds - window, end = seconds + window
        func speech(_ track: String) -> Double {
            segments.filter { $0.track == track }
                .reduce(0) { $0 + max(0, min($1.end, end) - max($1.start, start)) }
        }
        let tracks = ["system", "microphone"].sorted { speech($0) > speech($1) }
        for track in tracks where speech(track) > 0 {
            if let name = name(track: track, start: start, end: end) { return name }
        }
        return nil
    }
}
