import Foundation
import SwiftData

enum AppModelContainer {
    @MainActor static let shared: ModelContainer = {
        let schema = Schema([
            Customer.self,
            Project.self,
            Role.self,
            TimeEntry.self,
            ActivitySample.self,
            IdleInterval.self,
            CalendarEventLink.self,
            ClassificationRule.self,
            Todo.self
        ])
        let url = appSupportDirectory().appending(path: "TimeTracker.store")
        do {
            let container = try makeContainer(schema: schema, url: url)
            AppLogger.persistence.info("ModelContainer initialised at \(url.path, privacy: .public)")
            seedDefaultsIfEmpty(container: container)
            return container
        } catch {
            // A failed migration used to hit `fatalError` here, leaving the app
            // permanently unlaunchable with no recovery path and no backup. Instead:
            // move the unreadable store aside and start fresh, so the user always gets a
            // working app and their old data is preserved on disk for inspection.
            AppLogger.persistence.error("ModelContainer init failed: \(error.localizedDescription, privacy: .public)")
            AppLogger.log("persistence", level: .error, "container_failed: \(error.localizedDescription)")
            let moved = quarantineStore(at: url)
            do {
                let container = try makeContainer(schema: schema, url: url)
                AppLogger.persistence.notice("Recovered with a fresh store; previous store moved to \(moved ?? "-", privacy: .public)")
                AppLogger.log("persistence", level: .notice, "container_recovered moved=\(moved ?? "-")")
                seedDefaultsIfEmpty(container: container)
                return container
            } catch {
                AppLogger.persistence.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
                fatalError("ModelContainer init failed even after quarantine: \(error)")
            }
        }
    }()

    private static func makeContainer(schema: Schema, url: URL) throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Moves `TimeTracker.store` and its `-wal` / `-shm` siblings aside, timestamped.
    /// Returns the path the main file was moved to, if any.
    @discardableResult
    private static func quarantineStore(at url: URL) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        var movedMain: String?
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: "\(url.path).broken-\(stamp)\(suffix)")
            do {
                try fm.moveItem(at: src, to: dst)
                if suffix.isEmpty { movedMain = dst.path }
            } catch {
                AppLogger.persistence.error("Could not quarantine \(src.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return movedMain
    }

    private static func appSupportDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "TimeTracker", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private static func seedDefaultsIfEmpty(container: ModelContainer) {
        let ctx = ModelContext(container)
        let roleDescriptor = FetchDescriptor<Role>()
        let existing = (try? ctx.fetch(roleDescriptor)) ?? []
        guard existing.isEmpty else { return }
        let seeded: [Role] = [
            Role(name: "Solution Engineer", defaultBillable: true),
            Role(name: "Data Analyst", defaultBillable: true),
            Role(name: "Pre-Sales Engineer", defaultBillable: true)
        ]
        seeded.forEach { ctx.insert($0) }
        try? ctx.save()
        AppLogger.persistence.info("Seeded default roles")
    }
}
