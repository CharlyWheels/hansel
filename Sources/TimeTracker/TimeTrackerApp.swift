import SwiftUI
import SwiftData

@main
struct TimeTrackerApp: App {
    let container: ModelContainer

    @State private var controller: TimerController
    @State private var activityMonitor: ActivityMonitor
    @State private var idleMonitor: IdleMonitor
    @State private var calendarService: CalendarService
    @State private var suggestionEngine: SuggestionEngine
    @State private var watchdog: ActivityWatchdog
    @State private var completionService: EntryCompletionService

    init() {
        let c = AppModelContainer.shared
        self.container = c
        // All services share `container.mainContext` — the same context SwiftUI views
        // get via @Environment(\.modelContext). Writes from a TextField bound to a
        // @Model object and saves from the services end up in the same store, so
        // @Query observers (Timeline, Entries list, etc.) see every change immediately.
        let ctx = c.mainContext
        let ctrl = TimerController(modelContext: ctx)
        let idle = IdleMonitor(modelContext: ctx)
        let activity = ActivityMonitor(modelContext: ctx, idleMonitor: idle)
        let calendar = CalendarService(
            modelContext: ctx,
            timerController: ctrl,
            idleMonitor: idle
        )
        let engine = SuggestionEngine(modelContext: ctx)
        let watch = ActivityWatchdog(
            timerController: ctrl,
            idleMonitor: idle,
            suggestionEngine: engine
        )
        let completion = EntryCompletionService(
            timerController: ctrl,
            idleMonitor: idle,
            modelContext: ctx
        )
        _controller = State(wrappedValue: ctrl)
        _activityMonitor = State(wrappedValue: activity)
        _idleMonitor = State(wrappedValue: idle)
        _calendarService = State(wrappedValue: calendar)
        _suggestionEngine = State(wrappedValue: engine)
        _watchdog = State(wrappedValue: watch)
        _completionService = State(wrappedValue: completion)
        AppLogger.ui.info("TimeTrackerApp launched")
        AppLogger.log("ui", level: .info, "launch")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(controller)
                .environment(completionService)
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .environment(controller)
                .environment(completionService)
                .task { bootServicesOnce() }
        }
        .menuBarExtraStyle(.window)

        Window("Hansel", id: "main") {
            ContentView()
                .environment(controller)
                .environment(completionService)
                .modelContainer(container)
                .frame(minWidth: 960, minHeight: 640)
                .task { bootServicesOnce() }
        }

        Settings {
            SettingsView()
                .environment(controller)
                .environment(completionService)
                .modelContainer(container)
                .frame(width: 760, height: 520)
        }
    }

    @State private var servicesStarted = false

    private func bootServicesOnce() {
        guard !servicesStarted else { return }
        servicesStarted = true
        DataRetentionService.runIfDue(modelContext: container.mainContext)
        // IdleMonitor first so ActivityMonitor can skip sampling from the very first tick.
        idleMonitor.start()
        activityMonitor.start()
        watchdog.start()
        completionService.start()
        Task { await calendarService.start() }
        AppLogger.ui.info("Background services started")
        AppLogger.log("ui", level: .info, "services_started")
    }
}
