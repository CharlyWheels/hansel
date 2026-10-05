import XCTest
@testable import TimeTracker

final class WindowContextTests: XCTestCase {
    func test_documentBecomesTheURLAndKeepsTheTitle() {
        let c = ActivityMonitor.windowContext(title: "report.md", document: "file:///Users/me/acme/report.md")
        XCTAssertEqual(c.title, "report.md")
        XCTAssertEqual(c.url, "file:///Users/me/acme/report.md")
    }

    func test_emptyTitleIsDerivedFromTheDocument() {
        let c = ActivityMonitor.windowContext(title: "  ", document: "file:///Users/me/store-ml/train.py")
        XCTAssertEqual(c.title, "train.py — store-ml")
    }

    func test_noDocumentMeansNoURL() {
        let c = ActivityMonitor.windowContext(title: "carlos — zsh — ~/time-tracker", document: nil)
        XCTAssertEqual(c.title, "carlos — zsh — ~/time-tracker")
        XCTAssertNil(c.url)
        XCTAssertNil(ActivityMonitor.windowContext(title: "", document: nil).title)
    }

    func test_documentFolderActsAsTheSiteForSegmentation() {
        XCTAssertEqual(TitleTokenizer.hostKey(from: "file:///Users/me/store-ml/train.py"), "file:store-ml")
        XCTAssertEqual(TitleTokenizer.hostKey(from: "https://www.acme.com/docs/x"), "acme.com/docs")
    }
}
