import Foundation
import IOKit
import AppKit
import SwiftData

/// Polls IOKit's `HIDIdleTime` every few seconds AND listens for the screen-lock /
/// screen-unlock distributed notifications and system sleep / wake. The effective
/// "idle" state is:
///     (HIDIdleTime >= threshold)  OR  (screen is locked)  OR  (system asleep)
/// so the ActivityWatchdog won't fire during a locked session that hasn't yet crossed
/// the HID idle threshold, and ActivityMonitor skips sampling while locked.
@MainActor
final class IdleMonitor {
    private let modelContext: ModelContext
    private(set) var isIdle: Bool = false            // effective state (hid OR lock)
    private(set) var isScreenLocked: Bool = false
    /// Timers do not fire while the Mac sleeps and HIDIdleTime is small right after
    /// wake, so sleep has to be tracked explicitly or a night with the lid closed
    /// would never show up as idle.
    private(set) var isAsleep: Bool = false
    /// Whether the screen was locked or the Mac slept at any point in the current (or
    /// just-ended) idle span. That is never "listening on a call": the user was away.
    private(set) var currentIdleSawLockOrSleep = false
    /// When the user last came back from being idle. Nothing started automatically may
    /// be back-dated before it.
    private(set) var lastIdleEnd: Date?

    /// Fallback used when the user has never touched the Settings stepper.
    private let defaultThresholdSeconds: TimeInterval

    /// Live-read from UserDefaults on every tick so the Settings stepper takes effect
    /// without a restart, matching how EntryCompletionService reads its thresholds.
    ///
    /// Previously this was a stored property initialised to a hard-coded 5 minutes and
    /// never assigned again, while `SettingsView` happily wrote `idleThresholdMinutes`
    /// that nothing read — the stepper was inert.
    var thresholdSeconds: TimeInterval {
        guard let minutes = UserDefaults.standard.object(forKey: "idleThresholdMinutes") as? Int
        else { return defaultThresholdSeconds }
        return TimeInterval(max(1, minutes)) * 60
    }

    private var timer: Timer?
    private var openInterval: IdleInterval?
    /// Start of the idle span currently in progress, so an entry can be ended at the
    /// moment work actually stopped rather than when we noticed.
    var currentIdleStart: Date? { openInterval?.start }
    private var listeners: [(Bool) -> Void] = []
    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(modelContext: ModelContext, thresholdSeconds: TimeInterval = 5 * 60) {
        self.modelContext = modelContext
        self.defaultThresholdSeconds = thresholdSeconds
    }

    func start() {
        stop()
        closeOrphanedIntervals()
        // Initial lock state
        isScreenLocked = Self.queryScreenLocked()
        subscribeNotifications()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        AppLogger.idle.info("IdleMonitor started (threshold=\(self.thresholdSeconds, privacy: .public)s, locked=\(self.isScreenLocked, privacy: .public))")
        AppLogger.log("idle", level: .info, "start threshold=\(thresholdSeconds) locked=\(isScreenLocked)")
        // Reconcile once at startup in case we launched into an already-idle or
        // already-locked session.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observerTokens { center.removeObserver(token) }
        observerTokens.removeAll()
    }

    /// An interval left open by a crash or a quit while idle would otherwise read as
    /// "idle until now" to every consumer for as long as it is retained. Close it at
    /// its own start: we have no evidence of how long it really lasted.
    private func closeOrphanedIntervals() {
        let descriptor = FetchDescriptor<IdleInterval>(
            predicate: #Predicate<IdleInterval> { $0.end == nil }
        )
        guard let open = try? modelContext.fetch(descriptor), !open.isEmpty else { return }
        for interval in open { interval.end = interval.start }
        try? modelContext.save()
        AppLogger.log("idle", level: .info, "closed_orphaned count=\(open.count)")
    }

    /// Ends the open interval when the app quits, so it is not left dangling.
    private func closeOpenIntervalOnQuit() {
        guard let interval = openInterval else { return }
        interval.end = Date()
        openInterval = nil
        try? modelContext.save()
    }

    func onTransition(_ callback: @escaping (Bool) -> Void) {
        listeners.append(callback)
    }

    // MARK: - Tick

    private func tick() {
        let sinceInput = Self.secondsSinceLastInput()
        let hidIdle = sinceInput >= thresholdSeconds
        let effective = hidIdle || isScreenLocked || isAsleep
        guard effective != isIdle else { return }
        isIdle = effective
        if effective {
            // HID idle is only noticed once the threshold has passed; the user actually
            // stopped `sinceInput` seconds ago. A lock or sleep is noticed as it happens.
            let start = hidIdle && !isScreenLocked && !isAsleep
                ? Date().addingTimeInterval(-sinceInput)
                : Date()
            currentIdleSawLockOrSleep = isScreenLocked || isAsleep
            let interval = IdleInterval(start: start, end: nil)
            modelContext.insert(interval)
            openInterval = interval
            AppLogger.idle.info("Entered idle (hidIdle=\(hidIdle, privacy: .public) locked=\(self.isScreenLocked, privacy: .public))")
            AppLogger.log("idle", level: .info, "enter hidIdle=\(hidIdle) locked=\(isScreenLocked)")
        } else {
            openInterval?.end = Date()
            openInterval = nil
            lastIdleEnd = Date()
            AppLogger.idle.info("Exited idle")
            AppLogger.log("idle", level: .info, "exit")
        }
        try? modelContext.save()
        for cb in listeners { cb(effective) }
    }

    // MARK: - Screen-lock

    private func subscribeNotifications() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, NSNotification.Name("com.apple.screenIsLocked")) { $0.handleLockChange(true) }
        observe(distributed, NSNotification.Name("com.apple.screenIsUnlocked")) { $0.handleLockChange(false) }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.handleSleepChange(true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.handleSleepChange(false) }

        observe(NotificationCenter.default, NSApplication.willTerminateNotification) {
            $0.closeOpenIntervalOnQuit()
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: NSNotification.Name,
        _ handler: @escaping @MainActor (IdleMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observerTokens.append((center, token))
    }

    private func handleSleepChange(_ asleep: Bool) {
        guard asleep != isAsleep else { return }
        isAsleep = asleep
        if asleep { currentIdleSawLockOrSleep = true }
        AppLogger.log("idle", level: .info, "sleep_changed asleep=\(asleep)")
        tick()
    }

    private func handleLockChange(_ locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        if locked { currentIdleSawLockOrSleep = true }
        AppLogger.idle.info("Screen lock state changed → locked=\(locked, privacy: .public)")
        AppLogger.log("idle", level: .info, "lock_changed locked=\(locked)")
        tick()
    }

    /// CGSessionCopyCurrentDictionary returns metadata including whether the screen is
    /// locked. Used at startup to initialise state before the first distributed
    /// notification fires.
    private static func queryScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    // MARK: - IOKit HIDIdleTime

    static func secondsSinceLastInput() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS, let props = propsRef?.takeRetainedValue() else { return 0 }

        let key = "HIDIdleTime" as CFString
        guard let value = CFDictionaryGetValue(props, Unmanaged.passUnretained(key).toOpaque()) else {
            return 0
        }
        let cfNumber = Unmanaged<CFNumber>.fromOpaque(value).takeUnretainedValue()
        var nanoseconds: Int64 = 0
        CFNumberGetValue(cfNumber, .sInt64Type, &nanoseconds)
        return TimeInterval(nanoseconds) / 1_000_000_000.0
    }
}
