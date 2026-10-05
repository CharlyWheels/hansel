import XCTest
@testable import TimeTracker

final class ExportFormattingTests: XCTestCase {

    func test_csvNeutralisesFormulas() {
        XCTAssertEqual(ExportFormatting.csvField("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(ExportFormatting.csvField("+1"), "'+1")
        XCTAssertEqual(ExportFormatting.csvField("plain"), "plain")
    }

    func test_csvQuotesSeparatorsAndNewlines() {
        XCTAssertEqual(ExportFormatting.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(ExportFormatting.csvField("a\nb"), "\"a\nb\"")
    }

    func test_xmlTextEscapesMarkupAndDropsIllegalControlCharacters() {
        XCTAssertEqual(ExportFormatting.xmlText("a<b>&\"'"), "a&lt;b&gt;&amp;&quot;&apos;")
        XCTAssertEqual(ExportFormatting.xmlText("bad\u{0001}\u{000B}title\tok"), "badtitle\tok")
    }

    func test_excelSerialUsesLocalWallClock() {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        // 2026-10-05 09:00 in Madrid (UTC+2) is 07:00 UTC.
        let date = ISO8601DateFormatter().date(from: "2026-10-05T07:00:00Z")!
        let serial = ExportFormatting.excelSerial(date, timeZone: madrid)
        let fraction = serial - serial.rounded(.down)
        XCTAssertEqual(fraction, 9.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(ExportFormatting.localTimestamp(date, timeZone: madrid), "2026-10-05 09:00")
    }
}
