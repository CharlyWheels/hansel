import Foundation
import Observation

/// Starts a context collection from inside Hansel: everything new, or everything about
/// some todos the user is about to work on. It runs the same script launchd runs
/// (shipped in the app's Resources), which drives Codex; Codex reads the sources and
/// writes back through Hansel's MCP tools, so the pages update as items arrive.
@Observable
@MainActor
final class ContextRunner {

    enum Run: Equatable {
        case everything
        case todos(Set<UUID>)
    }

    private(set) var current: Run?
    private(set) var startedAt: Date?
    /// What the last run ended with, shown until the next one starts.
    private(set) var lastMessage: String?
    private(set) var lastFailed = false

    @ObservationIgnored private var process: Process?

    var isRunning: Bool { current != nil }

    func isGathering(_ todoID: UUID) -> Bool {
        if case let .todos(ids) = current { return ids.contains(todoID) }
        return false
    }

    static var scriptURL: URL? {
        Bundle.main.resourceURL?.appending(path: "context-ingest/run.sh")
    }

    static var reportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TimeTracker/context-ingest")
    }

    func collectEverything() { start(.everything, arguments: []) }

    func gather(_ todoIDs: [UUID]) {
        guard !todoIDs.isEmpty else { return }
        start(.todos(Set(todoIDs)), arguments: ["--todos", todoIDs.map(\.uuidString).joined(separator: ",")])
    }

    private func start(_ run: Run, arguments: [String]) {
        guard current == nil else { return }
        guard let script = Self.scriptURL, FileManager.default.isExecutableFile(atPath: script.path) else {
            finish(message: "The collection script is missing from this build of Hansel. Reinstall it with make install.", failed: true)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.ended(run, status: status) }
        }
        do {
            try process.run()
        } catch {
            finish(message: "Could not start the collection: \(error.localizedDescription)", failed: true)
            return
        }
        self.process = process
        current = run
        startedAt = Date()
        lastMessage = nil
        AppLogger.log("context", level: .info, "run_started kind=\(Self.kind(run))")
    }

    private func ended(_ run: Run, status: Int32) {
        process = nil
        current = nil
        startedAt = nil
        AppLogger.log("context", level: .info, "run_ended kind=\(Self.kind(run)) status=\(status)")
        switch status {
        case 0:
            let report = run == .everything ? "last-report.txt" : "last-todos-report.txt"
            let text = (try? String(contentsOf: Self.reportURL.appending(path: report), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finish(message: text?.isEmpty == false ? text! : "Done.", failed: false)
        case 75:
            finish(message: "Another collection was already running. Try again when it finishes.", failed: true)
        default:
            finish(message: "The collection failed (status \(status)). See ~/Library/Logs/TimeTracker/context-ingest-*.log.", failed: true)
        }
    }

    private func finish(message: String, failed: Bool) {
        lastMessage = message
        lastFailed = failed
    }

    private static func kind(_ run: Run) -> String {
        switch run {
        case .everything: return "everything"
        case let .todos(ids): return "todos(\(ids.count))"
        }
    }
}
