import Foundation

/// A few short moments of one voice, to listen to before naming it.
struct SpeakerClip: Equatable, Identifiable {
    let track: String
    let start: Double
    let end: Double
    /// What was said, when the transcript has a line for that moment.
    let text: String?

    var id: String { "\(track)@\(start)" }
    var duration: Double { end - start }
}

/// Picks the moments that best let the user recognise a voice. Pure, for tests.
///
/// Clips are the voice's own stretches of speech, which the diarizer cut at real
/// pauses, so each is a phrase rather than a cut in the middle of a word. Meeting
/// Notes splits its transcript into fixed ~1 s pieces, so the text shown is the
/// pieces that fall inside the clip, joined. A stretch someone else on the same
/// track talks over is skipped, and samples are spread over the meeting rather than
/// taken from one exchange.
enum SpeakerClips {

    static let minimumSeconds: Double = 2
    static let maximumSeconds: Double = 10
    /// The most recognisable length: long enough for a voice, short enough to skim.
    static let idealSeconds: Double = 6
    /// Samples closer than this would likely be the same exchange.
    static let minimumGap: Double = 60

    struct Line: Equatable {
        let track: String
        let start: Double
        let end: Double
        let text: String
    }

    static func samples(
        track: String,
        cluster: String,
        segments: [SpeakerTimeline.Segment],
        lines: [Line],
        count: Int = 3
    ) -> [SpeakerClip] {
        let own = segments.filter { $0.track == track && $0.cluster == cluster }
        let others = segments.filter { $0.track == track && $0.cluster != cluster }
        let trackLines = lines.filter { $0.track == track }.sorted { $0.start < $1.start }

        let candidates: [(clip: SpeakerClip, score: Double)] = own.compactMap { segment in
            let start = segment.start
            let end = min(segment.end, start + maximumSeconds)
            let length = end - start
            guard length >= minimumSeconds,
                  overlap(start, end, others) / length <= 0.2 else { return nil }
            let text = textBetween(start, end, in: trackLines)
            let clip = SpeakerClip(track: track, start: start, end: end, text: text)
            // Near the ideal length first; a clip with words to read beats one without.
            let score = -abs(length - idealSeconds) + (text == nil ? 0 : 2)
            return (clip, score)
        }

        var chosen: [SpeakerClip] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard chosen.count < count else { break }
            if chosen.allSatisfy({ abs($0.start - candidate.clip.start) >= minimumGap }) {
                chosen.append(candidate.clip)
            }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// Transcript pieces mostly inside [start, end], joined.
    static func textBetween(_ start: Double, _ end: Double, in lines: [Line]) -> String? {
        let words = lines.filter { line in
            let length = max(line.end - line.start, 0.01)
            return max(0, min(end, line.end) - max(start, line.start)) / length >= 0.5
        }
        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Seconds of [start, end] covered by the segments.
    private static func overlap(_ start: Double, _ end: Double, _ segments: [SpeakerTimeline.Segment]) -> Double {
        segments.reduce(0) { total, s in total + max(0, min(end, s.end) - max(start, s.start)) }
    }
}
