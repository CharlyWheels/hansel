import SwiftUI
import SwiftData

/// Starts the background services when the app finishes launching.
///
/// They used to start from `.task` on the menu-bar label and the main window. A
/// `MenuBarExtra` label is rendered into a status-item image, so its `.task` is not
/// guaranteed to run, and the window is not shown at launch for an `LSUIElement` app:
/// nothing might start until the user opened the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var boot: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Self.boot?() }
    }
}

@main
struct TimeTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    @State private var controller: TimerController
    @State private var activityMonitor: ActivityMonitor
    @State private var idleMonitor: IdleMonitor
    @State private var calendarService: CalendarService
    @State private var suggestionEngine: SuggestionEngine
    @State private var watchdog: ActivityWatchdog
    @State private var completionService: EntryCompletionService
    @State private var audioMonitor: AudioInputMonitor
    @State private var meetingDetector: MeetingDetector
    @State private var meetingProvider: MeetingProvider
    @State private var focusStore: FocusStore
    @State private var promptCenter: FocusPromptCenter
    @State private var arbiter: FocusArbiter
    @State private var meetingImporter: MeetingImporter
    @State private var proposalService: ProposalService
    @State private var diarization: DiarizationService
    @State private var summaryWriter: NamedSummaryWriter
    @State private var router = MainWindowRouter()
    @State private var meetingEnricher: MeetingTaskEnricher

    init() {
        // A second instance would open the same SQLite store, and if that failed it
        // would move the live store aside from under the first one.
        Self.exitIfAlreadyRunning()
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
        let audio = AudioInputMonitor()
        let meeting = MeetingDetector(audio: audio, idleMonitor: idle)
        completion.meetingDetector = meeting
        // Two-way wiring: the monitor stamps meeting flags onto each sample, and the
        // detector reads recent samples back for conference URLs the frontmost-app
        // stream would otherwise miss.
        activity.meetingDetector = meeting
        meeting.recentConferenceURL = { [weak ctx] in
            guard let ctx else { return false }
            let since = Date().addingTimeInterval(-300)
            let descriptor = FetchDescriptor<ActivitySample>(
                predicate: #Predicate<ActivitySample> { $0.timestamp >= since }
            )
            let recent = (try? ctx.fetch(descriptor)) ?? []
            return recent.contains { ConferenceCatalog.isConferenceURL($0.url) }
        }
        // --- Focus pipeline -------------------------------------------------------
        let meetings = MeetingProvider()
        let calendar = CalendarService(
            modelContext: ctx,
            timerController: ctrl,
            idleMonitor: idle,
            meetingProvider: meetings
        )
        meeting.trustworthyMeetingInProgress = { [weak meetings] in
            meetings?.trustworthyMeetingInProgress() ?? false
        }
        let store = FocusStore(modelContext: ctx, timerController: ctrl, meetingProvider: meetings)
        let prompts = FocusPromptCenter(timerController: ctrl, store: store, modelContext: ctx)

        var deps = FocusArbiter.Dependencies(
            buildContext: { [weak store] candidate in
                store?.buildBoundaryContext(for: candidate)
            },
            consult: { context in
                guard let provider = ProviderRegistry.defaultProvider() else {
                    throw AIError.noProviderConfigured
                }
                return try await provider.decideBoundary(context)
            },
            apply: { [weak prompts, weak store] action, _, decisionID in
                guard let prompts, let store else { return }
                prompts.present(
                    action,
                    decisionID: decisionID,
                    previousTitle: store.currentEntry()?.title ?? ""
                )
            },
            record: { [weak store] decision in store?.record(decision) }
        )
        deps.samples = { [weak store] from, to in store?.samples(from: from, to: to) ?? [] }
        deps.idleSpans = { [weak store] from, to in store?.idleSpans(from: from, to: to) ?? [] }
        deps.meetings = { [weak meetings] from, to in meetings?.meetings(from: from, to: to) ?? [] }
        deps.currentEntry = { [weak store] in store?.currentEntry() }
        deps.isIdle = { [weak idle] in idle?.isIdle ?? false }
        deps.idleStartedAt = { [weak idle] in idle?.currentIdleStart }
        deps.lastManualEditAt = { [weak ctrl] in ctrl?.lastManualEditAt }
        deps.allowedCalendarIds = { [weak meetings] in meetings?.allowedCalendarIds }
        deps.suppressedTransitions = { [weak store] in store?.suppressedTransitions() ?? [] }

        deps.persistBudget = { $0.persist() }
        deps.joinedMeeting = { [weak meeting, weak meetings] in
            guard UserDefaults.standard.object(forKey: "autoSwitchOnMeetingJoin") as? Bool ?? true,
                  let state = meeting?.state, state.isInMeeting,
                  let current = meetings?.currentMeeting(), current.isRealMeeting else { return nil }
            return (current, state.since ?? Date())
        }
        deps.labelsForMeeting = { [weak ctx] meeting in
            guard let ctx else { return (nil, nil, nil) }
            let (role, project, customer) = CalendarService.classify(title: meeting.title, context: ctx)
            let byAttendees = customer == nil
                ? CustomerMatcher.customer(
                    forDomains: meeting.attendeeDomains,
                    in: (try? ctx.fetch(FetchDescriptor<Customer>())) ?? []
                )
                : nil
            return (role?.name, project?.name, (customer ?? byAttendees)?.name)
        }

        let focusArbiter = FocusArbiter(dependencies: deps, budget: LLMBudget.loadPersisted())
        // The watchdog's drafts come out of the same daily allowance.
        watch.onModelCall = { [weak focusArbiter] in focusArbiter?.noteExternalModelCall() }
        watch.currentMeetingTitle = { [weak meetings] in meetings?.currentMeeting()?.title }
        prompts.onResolved = { [weak focusArbiter] in focusArbiter?.userResponded() }

        _controller = State(wrappedValue: ctrl)
        _activityMonitor = State(wrappedValue: activity)
        _idleMonitor = State(wrappedValue: idle)
        _calendarService = State(wrappedValue: calendar)
        _suggestionEngine = State(wrappedValue: engine)
        _watchdog = State(wrappedValue: watch)
        _completionService = State(wrappedValue: completion)
        _audioMonitor = State(wrappedValue: audio)
        _meetingDetector = State(wrappedValue: meeting)
        _meetingProvider = State(wrappedValue: meetings)
        _focusStore = State(wrappedValue: store)
        _promptCenter = State(wrappedValue: prompts)
        _arbiter = State(wrappedValue: focusArbiter)
        let importer = MeetingImporter(modelContext: ctx)
        _meetingImporter = State(wrappedValue: importer)
        let proposals = ProposalService(modelContext: ctx)
        importer.onImported = { [weak proposals] record, document in
            proposals?.meetingImported(record, document: document)
        }
        importer.onRemoved = { [weak proposals] ids in proposals?.meetingsRemoved(ids) }
        let enricher = MeetingTaskEnricher(modelContext: ctx)
        // Speakers come before the model: it judges whose task each item is better when
        // the transcript says who said what. Diarising takes seconds.
        let speakers = DiarizationService(modelContext: ctx)
        proposals.onProposalsCreated = { [weak speakers] record, _ in
            speakers?.meetingReady(record)
        }
        let nameSuggester = SpeakerNameSuggester(modelContext: ctx)
        speakers.onFinished = { [weak enricher] record in
            Task { await nameSuggester.suggest(for: record) }
            if let document = try? MeetingNotesArchive.load(record.folderURL) {
                enricher?.meetingReady(record, document: document)
            }
        }
        importer.onScanFinished = { [weak enricher, weak speakers] in
            speakers?.retryDue()
            enricher?.retryDue()
        }
        // Past decisions shape the next proposals: rules first, then the model's examples.
        proposals.learned = { [weak ctx] record in
            guard let ctx else { return (nil, nil) }
            let decisions = ProposalLearning.decisions(context: ctx)
            return (ProposalLearning.learnedProjectID(forMeetingTitle: record.title, decisions: decisions),
                    ProposalLearning.meetingHint(forMeetingTitle: record.title, decisions: decisions))
        }
        enricher.examples = { [weak ctx] in
            guard let ctx else { return ([], []) }
            return ProposalLearning.examples(decisions: ProposalLearning.decisions(context: ctx))
        }
        _meetingEnricher = State(wrappedValue: enricher)
        _proposalService = State(wrappedValue: proposals)
        _diarization = State(wrappedValue: speakers)
        let writer = NamedSummaryWriter(modelContext: ctx)
        speakers.onLabelsChanged = { [weak writer] record in writer?.namesChanged(record) }
        _summaryWriter = State(wrappedValue: writer)
        // Labels stored before a name was given (or by an older version) catch up.
        speakers.refreshAllLabels()
        AppLogger.ui.info("TimeTrackerApp launched")
        AppLogger.log("ui", level: .info, "launch")

        AppDelegate.boot = {
            Self.bootServicesOnce(
                container: c, idle: idle, audio: audio, meeting: meeting, activity: activity,
                watchdog: watch, completion: completion, arbiter: focusArbiter, prompts: prompts,
                meetings: meetings, calendar: calendar, importer: importer
            )
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(controller)
                .environment(completionService)
                .environment(promptCenter)
                .environment(meetingImporter)
                .environment(proposalService)
                .environment(diarization)
                .environment(summaryWriter)
                .environment(router)
                .environment(meetingEnricher)
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .environment(controller)
                .environment(completionService)
                .environment(promptCenter)
        }
        .menuBarExtraStyle(.window)

        Window("Hansel", id: "main") {
            ContentView()
                .environment(controller)
                .environment(completionService)
                .environment(promptCenter)
                .environment(meetingImporter)
                .environment(proposalService)
                .environment(diarization)
                .environment(summaryWriter)
                .environment(router)
                .environment(meetingEnricher)
                .modelContainer(container)
                .frame(minWidth: 960, minHeight: 640)
                // Fallback only; the app delegate normally starts everything first.
                .task { AppDelegate.boot?() }
        }

        Settings {
            SettingsView()
                .environment(controller)
                .environment(completionService)
                .environment(promptCenter)
                .environment(meetingImporter)
                .environment(proposalService)
                .environment(diarization)
                .environment(summaryWriter)
                .environment(router)
                .environment(meetingEnricher)
                .modelContainer(container)
                .frame(width: 760, height: 520)
        }
    }

    @MainActor private static var servicesStarted = false

    private static func exitIfAlreadyRunning() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me }
        guard let other = others.first else { return }
        other.activate()
        AppLogger.log("ui", level: .notice, "second_instance_exit other=\(other.processIdentifier)")
        exit(0)
    }

    /// The store could not be opened and was moved aside. Say so, with the path, rather
    /// than letting the user discover an empty app.
    private static func reportQuarantinedStoreIfAny() {
        guard let path = AppModelContainer.quarantinedStorePath else { return }
        let alert = NSAlert()
        alert.messageText = "Hansel could not open its data"
        alert.informativeText = "The previous database was moved to:\n\(path)\n\nHansel started with an empty one. Your old data is still in that file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private static func bootServicesOnce(
        container: ModelContainer,
        idle: IdleMonitor,
        audio: AudioInputMonitor,
        meeting: MeetingDetector,
        activity: ActivityMonitor,
        watchdog: ActivityWatchdog,
        completion: EntryCompletionService,
        arbiter: FocusArbiter,
        prompts: FocusPromptCenter,
        meetings: MeetingProvider,
        calendar: CalendarService,
        importer: MeetingImporter
    ) {
        guard !servicesStarted else { return }
        servicesStarted = true
        DataRetentionService.runIfDue(modelContext: container.mainContext)
        // IdleMonitor first so ActivityMonitor can skip sampling from the very first tick.
        idle.start()
        audio.start()
        meeting.start()
        activity.start()
        watchdog.start()
        completion.start()
        arbiter.start()
        prompts.start()
        importer.start()
        Task {
            await meetings.start()
            calendar.start()
        }
        reportQuarantinedStoreIfAny()
        // Registers this exact build with macOS; shows the system dialog only if needed.
        if Permissions.accessibilityStatus() != .granted { Permissions.requestAccessibility() }
        AppLogger.ui.info("Background services started")
        AppLogger.log("ui", level: .info, "services_started")
    }
}
