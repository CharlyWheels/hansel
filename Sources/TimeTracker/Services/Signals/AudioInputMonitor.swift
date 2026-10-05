import Foundation
import CoreAudio

/// Reports whether *something* on this Mac is currently capturing audio input.
///
/// This is the highest-value signal available for "am I actually in a meeting", and it
/// costs nothing: `kAudioDevicePropertyDeviceIsRunningSomewhere` is a read of a
/// CoreAudio HAL property, not a capture. There is no TCC prompt, no entitlement, no
/// orange indicator caused by us, and it behaves identically sandboxed or not.
///
/// What it cannot tell you is *who* is capturing. `capturingBundleIDs()` attempts that
/// through the process-object API, which is not annotated for availability in the SDK
/// and may be unavailable; it is treated strictly as an upgrade to confidence and every
/// caller must work without it.
///
/// Known blind spots, all handled by `ConferenceCatalog`'s veto list rather than here:
/// dictation, Voice Memos, GarageBand, screen recorders and audio routers all hold the
/// input device without a meeting being in progress.
@MainActor
final class AudioInputMonitor {

    private(set) var isCapturing = false
    /// When the current capturing state began — used to back-date a meeting's start to
    /// the moment the microphone actually opened, not when we noticed.
    private(set) var changedAt = Date()

    var onChange: ((Bool) -> Void)?

    private var reconcileTimer: Timer?
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListeners: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    // MARK: - Lifecycle

    func start() {
        stop()
        armSystemListener(for: kAudioHardwarePropertyDevices)
        armSystemListener(for: kAudioHardwarePropertyDefaultInputDevice)
        rearmDeviceListeners()
        // Listener delivery is unreliable for aggregate and virtual devices (Krisp,
        // ZoomAudioDevice, BlackHole) and the device set itself changes when a headset
        // connects, so reconcile on a slow timer as well. A handful of property reads.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
        AppLogger.activity.info("AudioInputMonitor started (capturing=\(self.isCapturing, privacy: .public))")
        AppLogger.log("activity", level: .info, "audio_start capturing=\(isCapturing)")
    }

    func stop() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        for (device, block) in deviceListeners {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
        for (selector, block) in systemListeners {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, DispatchQueue.main, block)
        }
        systemListeners.removeAll()
    }

    // MARK: - State

    private func reconcile() {
        // "Running somewhere" is per device, not per direction: a headset that is only
        // playing music reads as running. When the process API is available, require
        // a process that is actually running input.
        let deviceBusy = inputDeviceIDs().contains(where: isRunningSomewhere)
        var capturing = deviceBusy
        if deviceBusy, let anyInput = anyProcessRunningInput() {
            capturing = anyInput
        }
        guard capturing != isCapturing else { return }
        isCapturing = capturing
        changedAt = Date()
        AppLogger.activity.info("Audio input \(capturing ? "opened" : "closed", privacy: .public)")
        AppLogger.log("activity", level: .info, "audio_change capturing=\(capturing)")
        onChange?(capturing)
    }

    // MARK: - Listeners

    private func armSystemListener(for selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                // The set of devices changed; re-arm before reading.
                self?.rearmDeviceListeners()
                self?.reconcile()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(
            Self.systemObject, &address, DispatchQueue.main, block
        ) == noErr else { return }
        systemListeners[selector] = block
    }

    private func rearmDeviceListeners() {
        let devices = Set(inputDeviceIDs())

        for (device, block) in deviceListeners where !devices.contains(device) {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
            deviceListeners.removeValue(forKey: device)
        }

        for device in devices where deviceListeners[device] == nil {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.reconcile() }
            }
            // Removal requires the identical block object, so keep it.
            if AudioObjectAddPropertyListenerBlock(
                device, &address, DispatchQueue.main, block
            ) == noErr {
                deviceListeners[device] = block
            }
        }
    }

    // MARK: - CoreAudio reads

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Every device exposing at least one input channel.
    private func inputDeviceIDs() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            Self.systemObject, &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids.filter(hasInputChannels)
    }

    private func hasInputChannels(_ device: AudioObjectID) -> Bool {
        var address = Self.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    // MARK: - Per-process attribution (best effort)

    /// Bundle identifiers currently running audio *input*, or nil when this macOS build
    /// does not expose the process-object list.
    ///
    /// The constants carry no `API_AVAILABLE` annotation in the SDK, so an `#available`
    /// check would buy nothing — support is detected from the property read itself and
    /// cached. Treat a nil result as "unknown", never as "nobody is capturing".
    func capturingBundleIDs() -> Set<String>? {
        guard let processes = processObjects() else { return nil }
        var bundles: Set<String> = []
        for process in processes where isRunningInput(process) {
            if let bundle = bundleID(of: process), !bundle.isEmpty { bundles.insert(bundle) }
        }
        return bundles
    }

    /// Whether any process (bundled or not) is running audio input, or nil when the
    /// process-object API is unavailable.
    private func anyProcessRunningInput() -> Bool? {
        guard let processes = processObjects() else { return nil }
        return processes.contains(where: isRunningInput)
    }

    private func processObjects() -> [AudioObjectID]? {
        guard supportsProcessObjects != false else { return nil }

        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.systemObject, &address, 0, nil, &size) == noErr else {
            supportsProcessObjects = false
            AppLogger.log("activity", level: .info, "audio_process_api_unavailable")
            return nil
        }
        supportsProcessObjects = true
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            Self.systemObject, &address, 0, nil, &size, &processes
        ) == noErr else { return nil }
        return processes
    }

    private var supportsProcessObjects: Bool?

    private func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private func bundleID(of process: AudioObjectID) -> String? {
        var address = Self.address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
