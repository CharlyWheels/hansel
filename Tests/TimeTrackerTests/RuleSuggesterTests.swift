import XCTest
@testable import TimeTracker

final class RuleSuggesterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let api = UUID()
    private let data = UUID()

    /// An entry of `minutes` on `project`, `index` hours after t0, spent on `url`.
    private func work(_ project: UUID, _ index: Int, minutes: Int, url: String?,
                      bundle: String = "com.google.Chrome", app: String = "Chrome") -> ([RuleSuggester.Span], [RuleSuggester.Point]) {
        let start = t0.addingTimeInterval(Double(index) * 3600)
        let end = start.addingTimeInterval(Double(minutes) * 60)
        let points = stride(from: 0, to: minutes * 60, by: 30).map {
            RuleSuggester.Point(timestamp: start.addingTimeInterval(Double($0)), bundleId: bundle, appName: app, url: url)
        }
        return ([RuleSuggester.Span(projectID: project, start: start, end: end)], points)
    }

    private func suggest(_ parts: [([RuleSuggester.Span], [RuleSuggester.Point])],
                         fragments: [String] = []) -> [RuleSuggester.Suggestion] {
        RuleSuggester.suggest(spans: parts.flatMap(\.0), samples: parts.flatMap(\.1),
                              existingURLFragments: fragments, existingBundleIDs: [])
    }

    func test_suggestsAHostThatAlmostAlwaysMeansOneProject() {
        let parts = (0..<3).map { work(api, $0, minutes: 20, url: "https://acme.atlassian.net/browse/A-\($0)") }
        let s = suggest(parts)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.condition, .host("acme.atlassian.net/browse"))
        XCTAssertEqual(s.first?.projectID, api)
    }

    func test_noSuggestionWhenTheHostIsSplitAcrossProjects() {
        let parts = (0..<3).map { work(api, $0, minutes: 20, url: "https://docs.google.com/doc") }
            + (3..<6).map { work(data, $0, minutes: 20, url: "https://docs.google.com/doc") }
        XCTAssertTrue(suggest(parts).isEmpty)
    }

    func test_noSuggestionWhenARuleAlreadyCoversIt() {
        let parts = (0..<3).map { work(api, $0, minutes: 20, url: "https://acme.atlassian.net/browse/A") }
        XCTAssertTrue(suggest(parts, fragments: ["acme.atlassian.net"]).isEmpty)
    }

    func test_tooLittleEvidenceIsNotEnough() {
        let parts = (0..<2).map { work(api, $0, minutes: 30, url: "https://acme.atlassian.net/browse/A") }
        XCTAssertTrue(suggest(parts).isEmpty, "two entries are not a pattern")
    }

    func test_specificAppsCountButGenericOnesDoNot() {
        let tableau = (0..<3).map { work(data, $0, minutes: 20, url: nil, bundle: "com.tableausoftware.tableaudesktop", app: "Tableau") }
        XCTAssertEqual(suggest(tableau).first?.condition, .app(bundleId: "com.tableausoftware.tableaudesktop", name: "Tableau"))
        let terminal = (0..<3).map { work(data, $0, minutes: 20, url: nil, bundle: "com.apple.Terminal", app: "Terminal") }
        XCTAssertTrue(suggest(terminal).isEmpty)
    }
}
