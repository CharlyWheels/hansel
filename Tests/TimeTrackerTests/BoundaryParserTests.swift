import XCTest
@testable import TimeTracker

/// The parser is the app's defence against a confidently wrong model. These tests are
/// about refusing bad answers, not about parsing good ones.
final class BoundaryParserTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_003_600)
    private var boundary: Date { now.addingTimeInterval(-600) }

    private func context() -> BoundaryContext {
        BoundaryContext(
            currentEntry: EntryContext(id: UUID(), title: "Acme API", startAt: now.addingTimeInterval(-3600)),
            boundaryAt: boundary,
            segmenterScore: 0.6,
            reasons: [.appSwitch, .topicShift],
            before: [], after: [], idleSpans: [],
            meeting: nil, meetingCorroborated: false,
            projects: [], customers: [], roles: [], activeTodos: [], recentEntries: [],
            ruleHints: RuleEngine.Hints(),
            corrections: [],
            now: now,
            earliestAllowed: boundary.addingTimeInterval(-600),
            latestAllowed: now
        )
    }

    private func parse(_ text: String) throws -> BoundaryVerdict {
        try BoundaryParser.parse(text, context: context(), providerLabel: "test")
    }

    func test_parsesAWellFormedChange() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let verdict = try parse("""
        {"same_task": false, "boundary_at": "\(iso.string(from: boundary))",
         "title": "Globex migration", "role": null, "project": null,
         "customer": null, "todo": "T2", "confidence": 0.8, "rationale": "different repo"}
        """)
        XCTAssertFalse(verdict.sameTask)
        XCTAssertEqual(verdict.title, "Globex migration")
        XCTAssertEqual(verdict.todo, "T2")
        XCTAssertEqual(verdict.confidence, 0.8, accuracy: 1e-9)
        XCTAssertEqual(verdict.boundaryAt?.timeIntervalSince1970 ?? 0,
                       boundary.timeIntervalSince1970, accuracy: 1)
    }

    func test_hallucinatedTimestampIsClampedIntoTheAllowedWindow() throws {
        // A boundary three hours in the past would silently rewrite the whole day.
        let verdict = try parse("""
        {"same_task": false, "boundary_at": "2001-01-01T09:00:00Z",
         "title": "Something", "confidence": 0.9}
        """)
        let applied = try XCTUnwrap(verdict.boundaryAt)
        XCTAssertGreaterThanOrEqual(applied, boundary.addingTimeInterval(-600))
        XCTAssertLessThanOrEqual(applied, now)
    }

    func test_futureTimestampIsClampedToNow() throws {
        let verdict = try parse("""
        {"same_task": false, "boundary_at": "2099-01-01T09:00:00Z", "title": "X", "confidence": 0.5}
        """)
        XCTAssertEqual(verdict.boundaryAt, now)
    }

    func test_unparseableTimestampFallsBackToTheSegmentersInstant() throws {
        // The machine's own instant came from observed evidence and is always defensible.
        let verdict = try parse("""
        {"same_task": false, "boundary_at": "about ten minutes ago", "title": "X", "confidence": 0.5}
        """)
        XCTAssertEqual(verdict.boundaryAt, boundary)
    }

    func test_missingTimestampFallsBackToTheSegmentersInstant() throws {
        let verdict = try parse(#"{"same_task": false, "title": "X", "confidence": 0.5}"#)
        XCTAssertEqual(verdict.boundaryAt, boundary)
    }

    func test_sameTaskCarriesNoBoundary() throws {
        let verdict = try parse(#"{"same_task": true, "boundary_at": "2020-01-01T00:00:00Z", "confidence": 0.9}"#)
        XCTAssertTrue(verdict.sameTask)
        XCTAssertNil(verdict.boundaryAt, "a no-change verdict must not carry a cut point")
    }

    func test_missingSameTaskDefaultsToNoChange() throws {
        // The safe default is to leave the user's tracking alone.
        let verdict = try parse(#"{"title": "Something", "confidence": 0.9}"#)
        XCTAssertTrue(verdict.sameTask)
    }

    func test_jsonWrappedInProseAndFencesIsRecovered() throws {
        let verdict = try parse("""
        Here is my assessment:
        ```json
        {"same_task": false, "title": "Globex", "confidence": 0.7}
        ```
        Hope that helps.
        """)
        XCTAssertFalse(verdict.sameTask)
        XCTAssertEqual(verdict.title, "Globex")
    }

    func test_confidenceIsClampedAndDefaulted() throws {
        XCTAssertEqual(try parse(#"{"same_task": false, "confidence": 5}"#).confidence, 1)
        XCTAssertEqual(try parse(#"{"same_task": false, "confidence": -2}"#).confidence, 0)
        XCTAssertEqual(try parse(#"{"same_task": false}"#).confidence, 0)
    }

    func test_literalNullStringsBecomeNil() throws {
        let verdict = try parse(#"{"same_task": false, "title": "null", "todo": "  ", "role": ""}"#)
        XCTAssertNil(verdict.title)
        XCTAssertNil(verdict.todo)
        XCTAssertNil(verdict.role)
    }

    func test_garbageThrows() {
        XCTAssertThrowsError(try parse("no json here at all"))
    }
}
