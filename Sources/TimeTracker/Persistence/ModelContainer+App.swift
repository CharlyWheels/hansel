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
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.persistence.info("ModelContainer initialised at \(url.path, privacy: .public)")
            seedDefaultsIfEmpty(container: container)
            return container
        } catch {
            AppLogger.persistence.error("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            fatalError("ModelContainer init failed: \(error)")
        }
    }()

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
