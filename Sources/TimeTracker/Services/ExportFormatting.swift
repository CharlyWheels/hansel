import Foundation

/// Escaping shared by the CSV and XLSX exports. Titles come from window titles and
/// model output, so they can contain anything.
enum ExportFormatting {

    /// A CSV field, quoted when needed. A leading `=`, `+`, `-`, `@`, tab or CR makes
    /// spreadsheet apps evaluate the cell as a formula, so those get a `'` prefix.
    static func csvField(_ s: String) -> String {
        var value = s
        if let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            value = "'" + value
        }
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    /// XML text content: escapes markup and drops the control characters XML 1.0 does
    /// not allow at all, which would otherwise make Excel reject the whole file.
    static func xmlText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                let v = scalar.value
                let allowed = (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || v >= 0x10000
                if allowed { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Local wall-clock time, which is what a person reading a timesheet expects.
    static func localTimestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Excel's date serial (days since 1899-12-30) for the date's local wall-clock time.
    static func excelSerial(_ date: Date, timeZone: TimeZone = .current) -> Double {
        let local = date.timeIntervalSince1970 + TimeInterval(timeZone.secondsFromGMT(for: date))
        return local / 86_400 + 25_569
    }
}
