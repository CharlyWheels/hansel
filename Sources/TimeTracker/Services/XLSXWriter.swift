import Foundation

/// Writes an `AnalyticsReport` as a single-sheet `.xlsx` file.
///
/// The file is an OOXML (zipped XML) package. We generate the six required parts
/// in a temp directory, then shell out to `/usr/bin/zip` to assemble the archive
/// — macOS always ships `zip`, so no Swift dependency is needed.
///
/// Layout of the single sheet "Report":
///   A1  Time tracking report               (bold)
///   A2  Period: <start> – <end>            (plain)
///   A3  (blank)
///   A4  Summary                            (bold)
///   A5  Total                B5  <hours>
///   A6  Billable             B6  <hours>
///   A7  Entries              B7  <count>
///   A8  (blank)
///   A9  By Customer                        (bold)
///   A10 Name | Total (h) | Billable (h) | Share  (bold)
///   A11… rows
///   …By Project, By Role, Entries…
enum XLSXWriter {

    static func write(report: AnalyticsReport, to destination: URL) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appending(path: "TimeTracker-xlsx-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Static parts
        try writeFile(at: tempDir.appending(path: "[Content_Types].xml"), contents: contentTypesXML)
        try fm.createDirectory(
            at: tempDir.appending(path: "_rels"),
            withIntermediateDirectories: true
        )
        try writeFile(at: tempDir.appending(path: "_rels/.rels"), contents: rootRelsXML)
        try fm.createDirectory(
            at: tempDir.appending(path: "xl/_rels"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: tempDir.appending(path: "xl/worksheets"),
            withIntermediateDirectories: true
        )
        try writeFile(at: tempDir.appending(path: "xl/workbook.xml"), contents: workbookXML)
        try writeFile(at: tempDir.appending(path: "xl/_rels/workbook.xml.rels"), contents: workbookRelsXML)
        try writeFile(at: tempDir.appending(path: "xl/styles.xml"), contents: stylesXML)

        // The dynamic part — the sheet with our report data
        let sheetXML = buildSheet(report: report)
        try writeFile(at: tempDir.appending(path: "xl/worksheets/sheet1.xml"), contents: sheetXML)

        // Zip it. /usr/bin/zip on macOS accepts -r (recurse) and -X (no extra metadata).
        // If destination already exists, remove it first — zip would otherwise update in place.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try runZip(workingDirectory: tempDir, destination: destination)
    }

    // MARK: - Sheet construction

    private static func buildSheet(report: AnalyticsReport) -> String {
        var b = SheetBuilder()

        b.row([.boldString("Time tracking report")])
        b.row([.string(periodLabel(report: report))])
        b.row([])

        b.row([.boldString("Summary")])
        b.row([.string("Total (h)"), .number(hours(report.totalSeconds))])
        b.row([.string("Billable (h)"), .number(hours(report.billableSeconds))])
        b.row([.string("Entries"), .number(Double(report.entryCount))])
        b.row([])

        appendBreakdown(&b, title: "By Customer", rows: report.byCustomer)
        appendBreakdown(&b, title: "By Project", rows: report.byProject)
        appendBreakdown(&b, title: "By Role", rows: report.byRole)

        appendEntries(&b, entries: report.entries)

        return b.finish()
    }

    private static func appendBreakdown(_ b: inout SheetBuilder, title: String, rows: [BreakdownRow]) {
        b.row([.boldString(title)])
        b.row([
            .boldString("Name"), .boldString("Total (h)"),
            .boldString("Billable (h)"), .boldString("Share %")
        ])
        if rows.isEmpty {
            b.row([.string("(no entries)")])
        } else {
            for r in rows {
                b.row([
                    .string(r.name),
                    .number(hours(r.total)),
                    .number(hours(r.billable)),
                    .number((r.share * 100).rounded() / 1)
                ])
            }
        }
        b.row([])
    }

    private static func appendEntries(_ b: inout SheetBuilder, entries: [TimeEntry]) {
        b.row([.boldString("Entries")])
        b.row([
            .boldString("Title"), .boldString("Start"), .boldString("End"),
            .boldString("Duration (h)"), .boldString("Role"), .boldString("Project"),
            .boldString("Customer"), .boldString("Billable"), .boldString("Source"),
            .boldString("Notes")
        ])
        let iso = ISO8601DateFormatter()
        for e in entries {
            b.row([
                .string(e.title),
                .string(iso.string(from: e.startAt)),
                .string(e.endAt.map { iso.string(from: $0) } ?? ""),
                .number(hours(e.duration ?? 0)),
                .string(e.role?.name ?? ""),
                .string(e.project?.name ?? ""),
                .string(e.customer?.name ?? ""),
                .string(e.billableCached ? "yes" : "no"),
                .string(e.source.rawValue),
                .string(e.notes ?? "")
            ])
        }
    }

    // MARK: - Helpers

    private static func hours(_ seconds: TimeInterval) -> Double {
        (seconds / 3600 * 100).rounded() / 100   // 2 decimals
    }

    private static func periodLabel(report: AnalyticsReport) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return "Period: \(report.period.displayName) — \(df.string(from: report.interval.start)) to \(df.string(from: report.interval.end))"
    }

    private static func writeFile(at url: URL, contents: String) throws {
        try contents.data(using: .utf8)!.write(to: url)
    }

    private static func runZip(workingDirectory: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workingDirectory
        process.arguments = ["-rX", destination.path, "."]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "zip failed"
            AppLogger.log("ui", level: .error, "xlsx_zip_failed: \(msg)")
            throw NSError(
                domain: "TimeTracker.XLSX", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }

    // MARK: - Static OOXML parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Report" sheetId="1" r:id="rId1"/>
      </sheets>
    </workbook>
    """

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="2">
        <font><sz val="11"/><name val="Calibri"/></font>
        <font><b/><sz val="11"/><name val="Calibri"/></font>
      </fonts>
      <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
      <borders count="1"><border/></borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="2">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
      </cellXfs>
    </styleSheet>
    """
}

// MARK: - Sheet builder

/// Small struct that tracks the current row/column and emits OOXML cells.
private struct SheetBuilder {
    private var rows: [String] = []
    private var nextRow = 1

    enum Cell {
        case string(String)
        case boldString(String)
        case number(Double)
    }

    mutating func row(_ cells: [Cell]) {
        defer { nextRow += 1 }
        if cells.isEmpty {
            rows.append("<row r=\"\(nextRow)\"/>")
            return
        }
        var cellsXML = ""
        for (i, cell) in cells.enumerated() {
            let ref = "\(columnLetter(i + 1))\(nextRow)"
            cellsXML += cellXML(cell: cell, ref: ref)
        }
        rows.append("<row r=\"\(nextRow)\">\(cellsXML)</row>")
    }

    func finish() -> String {
        let sheetData = rows.joined(separator: "")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>\(sheetData)</sheetData>
        </worksheet>
        """
    }

    private func cellXML(cell: Cell, ref: String) -> String {
        switch cell {
        case .string(let s):
            return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(s))</t></is></c>"
        case .boldString(let s):
            return "<c r=\"\(ref)\" t=\"inlineStr\" s=\"1\"><is><t xml:space=\"preserve\">\(xmlEscape(s))</t></is></c>"
        case .number(let n):
            return "<c r=\"\(ref)\"><v>\(n)</v></c>"
        }
    }

    private func columnLetter(_ n: Int) -> String {
        // 1 -> A, 26 -> Z, 27 -> AA, …
        var result = ""
        var value = n
        while value > 0 {
            let rem = (value - 1) % 26
            result = String(UnicodeScalar(UInt8(65 + rem))) + result
            value = (value - 1) / 26
        }
        return result
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
