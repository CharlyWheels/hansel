import Foundation
import OSLog

/// Central logging facade. Uses `os.Logger` for Console.app visibility and a
/// rotating JSONL file sink at `~/Library/Logs/TimeTracker/` for the Debug pane.
enum AppLogger {
    /// Same as the bundle identifier, so Console filtering matches the app.
    static let subsystem = "com.carlosrueda.hansel"

    static let timer = Logger(subsystem: subsystem, category: "timer")
    static let activity = Logger(subsystem: subsystem, category: "activity")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let idle = Logger(subsystem: subsystem, category: "idle")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    static let fileSink = FileLogSink()

    static func log(_ category: String, level: LogLevel = .info, _ message: String) {
        fileSink.write(category: category, level: level.rawValue, message: message)
    }
}

enum LogLevel: String {
    case debug, info, notice, warning, error
}

final class FileLogSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "timetracker.log.file", qos: .utility)

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// False inside the test runner. Tests drive the real services, and their log
    /// lines (including deliberately failing model calls) used to land in the user's
    /// own log file, mixed in with real activity.
    static let isEnabled: Bool = NSClassFromString("XCTestCase") == nil

    func write(category: String, level: String, message: String) {
        guard Self.isEnabled else { return }
        let now = Date()
        queue.async { [isoFormatter, fileNameFormatter] in
            let line = Self.jsonLine(
                ts: isoFormatter.string(from: now),
                category: category,
                level: level,
                message: message
            )
            let url = Self.logsDirectory()
                .appending(path: "timetracker-\(fileNameFormatter.string(from: now)).log")
            Self.append(line, to: url)
            Self.rotateIfNeeded(maxAgeDays: 14)
        }
    }

    static var currentLogDirectory: URL { logsDirectory() }

    // MARK: - private

    private static func logsDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "Logs/TimeTracker", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func append(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func jsonLine(ts: String, category: String, level: String, message: String) -> String {
        let payload: [String: String] = [
            "ts": ts, "cat": category, "lvl": level, "msg": message
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str + "\n"
        }
        return "{\"ts\":\"\(ts)\",\"cat\":\"\(category)\",\"lvl\":\"\(level)\",\"msg\":\"unserialisable\"}\n"
    }

    private static func rotateIfNeeded(maxAgeDays: Int) {
        let dir = logsDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(maxAgeDays) * 86_400)
        for url in files where url.pathExtension == "log" {
            if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
