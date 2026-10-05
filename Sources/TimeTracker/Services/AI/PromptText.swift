import Foundation

/// Helpers for putting text we do not control into a prompt, and for getting JSON back
/// out of a model's answer.
enum PromptText {

    /// Window titles, URLs and calendar titles are written by whoever made the web
    /// page, email or invite. Flatten them to one short line so they cannot fake a
    /// section header or an instruction, and neutralise angle brackets so they cannot
    /// close the `<activity>` tag the prompt wraps them in.
    static func untrusted(_ s: String, limit: Int = 200) -> String {
        var out = ""
        var lastWasSpace = false
        for scalar in s.unicodeScalars {
            let isBreak = CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            if isBreak || scalar == " " || scalar == "\t" {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            switch scalar {
            case "<": out.append("‹")
            case ">": out.append("›")
            default: out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }

    /// The first complete, balanced JSON object in `text`, respecting strings.
    ///
    /// Taking "first `{` to last `}`" broke whenever prose after the JSON contained a
    /// brace, or the model returned two objects.
    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                if start != nil { inString = true }
            case "{":
                if start == nil { start = i }
                depth += 1
            case "}":
                guard let s = start else { continue }
                depth -= 1
                if depth == 0 { return String(chars[s...i]) }
            default:
                break
            }
        }
        return nil
    }

    /// Local time with its UTC offset, e.g. `2026-10-05T14:03:10+02:00`, so the model
    /// never has to guess which zone a time is in.
    static func localISO(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
