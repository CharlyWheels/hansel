import Foundation

/// Turns Meeting Notes' short transcript fragments into readable paragraphs.
enum TranscriptGrouping {

    struct Paragraph: Equatable, Identifiable {
        let start: TimeInterval
        let speaker: Speaker
        var text: String
        var id: TimeInterval { start }
    }

    /// Meeting Notes does not identify speakers, but it records the microphone and the
    /// system audio as separate tracks. On a call that separates this Mac's user from
    /// everyone on the far end; in a room, everyone is on the microphone.
    enum Speaker: Equatable {
        case me, others, unknown

        init(source: String?) {
            switch source {
            case "microphone": self = .me
            case "system": self = .others
            default: self = .unknown
            }
        }

        var label: String {
            switch self {
            case .me: return "Me"
            case .others: return "Others"
            case .unknown: return ""
            }
        }
    }

    /// Consecutive fragments from the same track join one paragraph until a pause of
    /// `maxGap` seconds or `maxLength` seconds of speech.
    static func paragraphs(
        _ turns: [MeetingNotesDocument.Turn],
        maxGap: TimeInterval = 20,
        maxLength: TimeInterval = 90
    ) -> [Paragraph] {
        var out: [Paragraph] = []
        var lastStart: TimeInterval = -.infinity
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = Speaker(source: turn.source)
            if var last = out.last, last.speaker == speaker,
               turn.start - lastStart <= maxGap, turn.start - last.start <= maxLength {
                last.text += " " + text
                out[out.count - 1] = last
            } else {
                out.append(Paragraph(start: turn.start, speaker: speaker, text: text))
            }
            lastStart = turn.start
        }
        return out
    }

    /// `m:ss`, or `h:mm:ss` past the hour.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The transcript around `seconds`, for a model or a tooltip: what was said from a
    /// little before the moment to a little after.
    static func excerpt(
        _ turns: [MeetingNotesDocument.Turn],
        around seconds: TimeInterval,
        before: TimeInterval = 60,
        after: TimeInterval = 45,
        limit: Int = 1200
    ) -> String {
        let window = turns.filter { $0.start >= seconds - before && $0.start <= seconds + after }
        let text = paragraphs(window).map { p in
            let who = p.speaker.label.isEmpty ? "" : "\(p.speaker.label): "
            return "[\(timestamp(p.start))] \(who)\(p.text)"
        }.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
