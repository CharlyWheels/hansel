import Foundation
import SwiftData

@Model
final class ActivitySample {
    var timestamp: Date
    var bundleId: String
    var appName: String
    var windowTitle: String?
    var url: String?

    init(
        timestamp: Date = Date(),
        bundleId: String,
        appName: String,
        windowTitle: String? = nil,
        url: String? = nil
    ) {
        self.timestamp = timestamp
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
    }
}
