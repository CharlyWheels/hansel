import XCTest
@testable import TimeTracker

final class LoggingTests: XCTestCase {
    func test_testsNeverWriteToTheUsersLogFile() throws {
        XCTAssertFalse(FileLogSink.isEnabled)

        let dir = FileLogSink.currentLogDirectory
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let file = dir.appending(path: "timetracker-\(f.string(from: Date())).log")
        let before = (try? Data(contentsOf: file))?.count ?? 0

        let marker = "logging-test-\(UUID().uuidString)"
        AppLogger.log("ui", level: .info, marker)
        // The sink writes on a background queue; give it a moment.
        Thread.sleep(forTimeInterval: 0.3)

        let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertFalse(contents.contains(marker))
        XCTAssertGreaterThanOrEqual((try? Data(contentsOf: file))?.count ?? 0, before)
    }
}
