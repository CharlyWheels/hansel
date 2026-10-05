import Foundation
import SwiftData

@Model
final class ActivitySample {
    var timestamp: Date
    var bundleId: String
    var appName: String
    var windowTitle: String?
    var url: String?

    /// `SignalFlags` bitmask: mic / camera / video-call app / conference URL.
    /// One packed field rather than three Bools, so future signals cost no migration.
    /// Default on the declaration so SwiftData lightweight migration applies it.
    var flagsRaw: Int = 0

    init(
        timestamp: Date = Date(),
        bundleId: String,
        appName: String,
        windowTitle: String? = nil,
        url: String? = nil,
        flags: SignalFlags = []
    ) {
        self.timestamp = timestamp
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.flagsRaw = flags.rawValue
    }

    var flags: SignalFlags {
        get { SignalFlags(rawValue: flagsRaw) }
        set { flagsRaw = newValue.rawValue }
    }
}
