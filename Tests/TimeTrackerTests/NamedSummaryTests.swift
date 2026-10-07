import XCTest
import SwiftData
@testable import TimeTracker

@MainActor
final class NamedSummaryTests: XCTestCase {

    private let timeline = SpeakerTimeline(
        segments: [
            .init(track: "microphone", start: 0, end: 100, cluster: "S1"),
            .init(track: "system", start: 100, end: 200, cluster: "S2"),
        ],
        names: ["S1@microphone": "Carlos Rueda", "S2@system": "Pablo Lopez"]
    )

    func test_namesKeyNeedsAtLeastOneRealName() {
        XCTAssertNotNil(NamedSummaryWriter.namesKey(timeline))
        let unnamed = SpeakerTimeline(segments: timeline.segments,
                                      names: ["S1@microphone": "Speaker 1", "S2@system": "Speaker 2"])
        XCTAssertNil(NamedSummaryWriter.namesKey(unnamed), "nothing to rewrite with")
        XCTAssertNil(NamedSummaryWriter.namesKey(nil))
    }

    func test_promptAttributesStatementsAndKeepsTheOriginal() {
        var insights = MeetingNotesDocument.Insights(summary: "Un interlocutor explicó la demo.")
        insights.keyStatements = [.init(text: "Preparo la demo", timestamp: 30, owner: "Interlocutor no identificado"),
                                  .init(text: "Revisa el stock", timestamp: 150, owner: nil)]
        let doc = MeetingNotesDocument(id: UUID(), title: "Sync", startedAt: Date(), insights: insights)
        let (system, user) = NamedSummaryWriter.prompt(document: doc, insights: insights, timeline: timeline,
                                                       userNames: ["Carlos"])
        XCTAssertTrue(system.contains("When unsure, keep the generic wording"))
        XCTAssertTrue(user.contains("Un interlocutor explicó la demo."))
        XCTAssertTrue(user.contains("said by Carlos Rueda: Preparo la demo"))
        XCTAssertTrue(user.contains("said by Pablo Lopez: Revisa el stock"))
    }

    func test_parse() {
        XCTAssertEqual(NamedSummaryWriter.parse(#"Sure: {"summary": "Carlos explicó la demo."}"#),
                       "Carlos explicó la demo.")
        XCTAssertNil(NamedSummaryWriter.parse(#"{"summary": "  "}"#))
        XCTAssertNil(NamedSummaryWriter.parse("no json"))
    }
}
