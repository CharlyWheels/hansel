import Foundation
import IOKit
import AppKit
import SwiftData

/// Polls IOKit's `HIDIdleTime` every few seconds AND listens for the screen-lock /
/// screen-unlock distributed notifications. The effective "idle" state is:
///     (HIDIdleTime >= threshold)  OR  (screen is locked)
/// so the ActivityWatchdog won't fire during a locked session that hasn't yet crossed
/// the HID idle threshold, and ActivityMonitor skips sampling while locked.
@MainActor
final class IdleMonitor {
    private let modelContext: ModelContext
    private(set) var isIdle: Bool = false            // effective state (hid OR lock)
    private(set) var isScreenLocked: Bool = false
    var thresholdSeconds: TimeInterval {
        didSet { AppLogger.idle.debug("threshold changed to \(self.thresholdSeconds)s") }
    }

    private var timer: Timer?
    private var openInterval: IdleInterval?
    private var listeners: [(Bool) -> Void] = []

    init(modelContext: ModelContext, thresholdSeconds: TimeInterval = 5 * 60) {
        self.modelContext = modelContext
        self.thresholdSeconds = thresholdSeconds
    }

    func start() {
        stop()
        // Initial lock state
        isScreenLocked = Self.queryScreenLocked()
        subscribeLockNotifications()
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
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func onTransition(_ callback: @escaping (Bool) -> Void) {
        listeners.append(callback)
    }

    // MARK: - Tick

    private func tick() {
        let hidIdle = Self.secondsSinceLastInput() >= thresholdSeconds
        let effective = hidIdle || isScreenLocked
        guard effective != isIdle else { return }
        isIdle = effective
        if effective {
            let interval = IdleInterval(start: Date(), end: nil)
            modelContext.insert(interval)
            openInterval = interval
            AppLogger.idle.info("Entered idle (hidIdle=\(hidIdle, privacy: .public) locked=\(self.isScreenLocked, privacy: .public))")
            AppLogger.log("idle", level: .info, "enter hidIdle=\(hidIdle) locked=\(isScreenLocked)")
        } else {
            openInterval?.end = Date()
            openInterval = nil
            AppLogger.idle.info("Exited idle")
            AppLogger.log("idle", level: .info, "exit")
        }
        try? modelContext.save()
        for cb in listeners { cb(effective) }
    }

    // MARK: - Screen-lock

    private func subscribeLockNotifications() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleLockChange(true) }
        }
        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleLockChange(false) }
        }
    }

    private func handleLockChange(_ locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
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
