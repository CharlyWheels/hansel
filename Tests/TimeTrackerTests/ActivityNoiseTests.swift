import XCTest
@testable import TimeTracker

@MainActor
final class ActivityNoiseTests: XCTestCase {
    func test_systemSurfacesAreNotRecordedAsWork() {
        XCTAssertTrue(ActivityMonitor.isIgnored("com.apple.UserNotificationCenter"))
        XCTAssertTrue(ActivityMonitor.isIgnored("com.apple.loginwindow"))
        XCTAssertTrue(ActivityMonitor.isIgnored("com.carlosrueda.hansel"))
        XCTAssertFalse(ActivityMonitor.isIgnored("com.apple.Terminal"))
        XCTAssertFalse(ActivityMonitor.isIgnored("com.google.Chrome"))
    }
}
