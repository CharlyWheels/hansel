import XCTest
import SwiftData
@testable import TimeTracker

/// Assistants reach Hansel through MCP: the JSON-RPC handshake, the tools, and the
/// socket the stdio relay connects to.
@MainActor
final class MCPTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var controller: TimerController!
    private var handler: MCPHandler!

    override func setUp() async throws {
        container = try AppModelContainer.inMemory()
        controller = TimerController(modelContext: context)
        let tools = MCPTools(context: context, controller: controller, proposals: ProposalService(modelContext: context))
        handler = MCPHandler(tools: tools)
    }

    // MARK: - Helpers

    private var nextID = 0

    private func send(_ method: String, _ params: JSONObject = [:]) throws -> JSONObject {
        nextID += 1
        let message: JSONObject = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
        let reply = try XCTUnwrap(handler.handle(JSONSerialization.data(withJSONObject: message)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? JSONObject)
    }

    /// Calls a tool; returns its text and whether it failed.
    private func call(_ name: String, _ arguments: JSONObject = [:]) throws -> (text: String, isError: Bool) {
        let reply = try send("tools/call", ["name": name, "arguments": arguments])
        let result = try XCTUnwrap(reply["result"] as? JSONObject, "\(reply)")
        let content = try XCTUnwrap(result["content"] as? [JSONObject])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    private func callOK(_ name: String, _ arguments: JSONObject = [:], file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        let (text, isError) = try call(name, arguments)
        XCTAssertFalse(isError, text, file: file, line: line)
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func object(_ name: String, _ arguments: JSONObject = [:], file: StaticString = #filePath, line: UInt = #line) throws -> JSONObject {
        try XCTUnwrap(try callOK(name, arguments, file: file, line: line) as? JSONObject, file: file, line: line)
    }

    private func iso(_ date: Date) -> String { MCPTools.format(date) }

    private func allEntries() -> [TimeEntry] {
        (try? context.fetch(FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startAt)]))) ?? []
    }

    // MARK: - Protocol

    func test_initializeEchoesASupportedVersionAndAdvertisesTools() throws {
        let reply = try send("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        let result = try XCTUnwrap(reply["result"] as? JSONObject)
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? JSONObject)?["tools"])
        XCTAssertEqual((result["serverInfo"] as? JSONObject)?["name"] as? String, "hansel")

        let unknown = try send("initialize", ["protocolVersion": "1999-01-01"])
        XCTAssertEqual((unknown["result"] as? JSONObject)?["protocolVersion"] as? String, MCPHandler.supportedProtocolVersions[0])
    }

    func test_notificationsGetNoReplyAndUnknownMethodsAnError() throws {
        let note: JSONObject = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        XCTAssertNil(handler.handle(try JSONSerialization.data(withJSONObject: note)))
        let reply = try send("resources/list")
        XCTAssertEqual((reply["error"] as? JSONObject)?["code"] as? Int, -32601)
        let garbage = try XCTUnwrap(handler.handle(Data("{not json".utf8)))
        XCTAssertTrue(String(decoding: garbage, as: UTF8.self).contains("-32700"))
    }

    func test_toolListHasSchemasAndNoWayToDelete() throws {
        let reply = try send("tools/list")
        let tools = try XCTUnwrap((reply["result"] as? JSONObject)?["tools"] as? [JSONObject])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("get_today"))
        XCTAssertTrue(names.contains("create_entry"))
        XCTAssertFalse(names.contains { $0.contains("delete") || $0.contains("remove") })
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? JSONObject)
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(tool["description"] as? String)
            let annotations = try XCTUnwrap(tool["annotations"] as? JSONObject)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
        }
    }

    func test_toolFailureIsAReadableResultNotAProtocolError() throws {
        let (text, isError) = try call("get_entry", ["id": "nope"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("not an entry id"))
        let unknown = try send("tools/call", ["name": "drop_database"])
        XCTAssertNotNil(unknown["error"])
    }

    // MARK: - Timer and entries

    func test_startAndStopTimerWithProjectByName() throws {
        let acme = try XCTUnwrap(HanselActions.addCustomer(name: "Acme", context: context))
        HanselActions.addProject(name: "Website", customer: acme, context: context)

        let started = try object("start_timer", ["title": "Homepage", "project": "website"])
        XCTAssertEqual(started["running"] as? Bool, true)
        XCTAssertEqual((started["project"] as? JSONObject)?["name"] as? String, "Website")
        XCTAssertEqual((started["customer"] as? JSONObject)?["name"] as? String, "Acme", "the project brings its customer")
        XCTAssertEqual(controller.runningEntry?.title, "Homepage")

        let stopped = try object("stop_timer")
        XCTAssertEqual(stopped["running"] as? Bool, false)
        XCTAssertNil(controller.runningEntry)
        XCTAssertTrue(try call("stop_timer").isError, "nothing is running any more")
    }

    func test_createEntryRefusesOverlapsAndFutureTimes() throws {
        let now = Date()
        let created = try object("create_entry", [
            "title": "Forgot this", "start": iso(now.addingTimeInterval(-7200)), "end": iso(now.addingTimeInterval(-3600)),
        ])
        XCTAssertEqual(created["duration_minutes"] as? Int, 60)
        let entry = try XCTUnwrap(allEntries().first)
        XCTAssertTrue(entry.isHumanConfirmed)

        let overlap = try call("create_entry", [
            "title": "Clash", "start": iso(now.addingTimeInterval(-5400)), "end": iso(now.addingTimeInterval(-1800)),
        ])
        XCTAssertTrue(overlap.isError)
        XCTAssertTrue(overlap.text.contains("Forgot this"))

        let future = try call("create_entry", [
            "title": "Later", "start": iso(now.addingTimeInterval(600)), "end": iso(now.addingTimeInterval(1200)),
        ])
        XCTAssertTrue(future.isError)
        XCTAssertEqual(allEntries().count, 1)
    }

    func test_updateEntryChangesOnlyGivenFieldsAndClearsWithEmptyString() throws {
        let project = try XCTUnwrap(HanselActions.addProject(name: "Internal", context: context))
        let now = Date()
        let entry = TimeEntry(title: "Old", startAt: now.addingTimeInterval(-3600), endAt: now.addingTimeInterval(-1800),
                              project: project, source: .aiAutoStart, notes: "keep")
        context.insert(entry)

        let updated = try object("update_entry", ["id": entry.id.uuidString, "title": "New", "project": ""])
        XCTAssertEqual(updated["title"] as? String, "New")
        XCTAssertTrue(updated["project"] is NSNull)
        XCTAssertEqual(entry.notes, "keep")
        XCTAssertTrue(entry.isHumanConfirmed)

        // Moving its own times inside its own span is not an overlap.
        _ = try object("update_entry", ["id": entry.id.uuidString, "start": iso(now.addingTimeInterval(-3000))])
        XCTAssertEqual(entry.startAt.timeIntervalSince1970, now.addingTimeInterval(-3000).timeIntervalSince1970, accuracy: 1)
    }

    func test_runningEntryCannotBeEndedThroughUpdate() throws {
        controller.startManual(title: "Live")
        let id = try XCTUnwrap(controller.runningEntry?.id)
        XCTAssertTrue(try call("update_entry", ["id": id.uuidString, "end": iso(Date())]).isError)
        let renamed = try object("update_entry", ["id": id.uuidString, "title": "Live, renamed"])
        XCTAssertEqual(renamed["running"] as? Bool, true)
        XCTAssertNotNil(controller.lastManualEditAt)
    }

    func test_listEntriesFiltersAndGetReportTotals() throws {
        let customer = try XCTUnwrap(HanselActions.addCustomer(name: "Acme", context: context))
        let project = try XCTUnwrap(HanselActions.addProject(name: "Site", customer: customer, context: context))
        let role = try XCTUnwrap(HanselActions.addRole(name: "Dev", context: context))
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60)
        guard Date().timeIntervalSince(start) > 2 * 3600 else { throw XCTSkip("needs two hours of today behind us") }
        let billed = TimeEntry(title: "Billed", startAt: start, endAt: start.addingTimeInterval(3600),
                               role: role, project: project, customer: customer)
        billed.refreshBillableCache()
        let other = TimeEntry(title: "Admin", startAt: start.addingTimeInterval(3600), endAt: start.addingTimeInterval(5400))
        context.insert(billed); context.insert(other)

        let onlySite = try XCTUnwrap(try callOK("list_entries", ["project": "Site"]) as? [JSONObject])
        XCTAssertEqual(onlySite.map { $0["title"] as? String }, ["Billed"])

        let report = try object("get_report", ["period": "today"])
        XCTAssertEqual(report["total_hours"] as? Double, 1.5)
        XCTAssertEqual(report["billable_hours"] as? Double, 1.0)
        let byCustomer = try XCTUnwrap(report["by_customer"] as? [JSONObject])
        XCTAssertEqual(byCustomer.first?["name"] as? String, "Acme")

        let today = try object("get_today")
        XCTAssertEqual((today["entries"] as? [Any])?.count, 2)
    }

    // MARK: - Names

    func test_ambiguousNamesAreRefusedWithCandidates() throws {
        HanselActions.addProject(name: "Website A", context: context)
        HanselActions.addProject(name: "Website B", context: context)
        let (text, isError) = try call("start_timer", ["title": "x", "project": "Website"])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("Website A") && text.contains("Website B"))
        XCTAssertNil(controller.runningEntry)

        let missing = try call("start_timer", ["title": "x", "project": "Nope"])
        XCTAssertTrue(missing.text.contains("Known:"))
    }

    // MARK: - Todos and catalog

    func test_todosCreateNestCompleteAndRefuseCycles() throws {
        let parent = try object("create_todo", ["title": "Launch", "due": "2026-12-01"])
        let child = try object("create_todo", ["title": "Write copy", "parent": "Launch"])
        XCTAssertEqual(child["parent_id"] as? String, parent["id"] as? String)
        XCTAssertEqual(child["path"] as? String, "Launch › Write copy")

        XCTAssertTrue(try call("update_todo", ["todo": "Launch", "parent": "Write copy"]).isError)

        let done = try object("update_todo", ["todo": "Write copy", "completed": true])
        XCTAssertEqual(done["completed"] as? Bool, true)
        XCTAssertFalse(done["completed_at"] is NSNull)

        let open = try XCTUnwrap(try callOK("list_todos") as? [JSONObject])
        XCTAssertEqual(open.map { $0["title"] as? String }, ["Launch"])
        let all = try XCTUnwrap(try callOK("list_todos", ["include_completed": true]) as? [JSONObject])
        XCTAssertEqual(all.map { $0["title"] as? String }, ["Launch", "Write copy"])

        let moved = try object("update_todo", ["todo": "Write copy", "parent": "", "due": ""])
        XCTAssertTrue(moved["parent_id"] is NSNull)
    }

    func test_catalogCreateUpdateAndBillableRecache() throws {
        _ = try object("create_customer", ["name": "Acme", "email_domains": "acme.com"])
        XCTAssertTrue(try call("create_customer", ["name": "acme"]).isError, "duplicate names are refused")
        _ = try object("create_project", ["name": "Site", "customer": "Acme", "details": "Marketing site"])
        _ = try object("create_role", ["name": "Dev"])

        let now = Date()
        _ = try object("create_entry", [
            "title": "Work", "start": iso(now.addingTimeInterval(-3600)), "end": iso(now.addingTimeInterval(-60)),
            "project": "Site", "role": "Dev",
        ])
        let entry = try XCTUnwrap(allEntries().first)
        XCTAssertTrue(entry.billableCached)

        let project = try object("update_project", ["project": "Site", "default_billable": false, "name": "Website"])
        XCTAssertEqual(project["name"] as? String, "Website")
        XCTAssertFalse(entry.billableCached, "past entries follow the new default")

        let role = try object("update_role", ["role": "Dev", "name": "Engineering"])
        XCTAssertEqual(role["name"] as? String, "Engineering")
    }

    // MARK: - Meetings and proposals

    func test_renameMeetingAndDecideProposals() throws {
        let record = MeetingRecord(id: UUID(), title: "Wrong", startedAt: Date().addingTimeInterval(-3600),
                                   folderPath: "/nonexistent", fileModifiedAt: Date())
        context.insert(record)
        let proposal = TodoProposal(meetingID: record.id, sourceKey: "\(record.id)#0", meetingTitle: "Wrong",
                                    meetingStartedAt: record.startedAt, title: "Send deck", evidence: "Send deck")
        let other = TodoProposal(meetingID: record.id, sourceKey: "\(record.id)#1", meetingTitle: "Wrong",
                                 meetingStartedAt: record.startedAt, title: "Book room", evidence: "Book room")
        context.insert(proposal); context.insert(other)
        try context.save()

        let renamed = try object("rename_meeting", ["id": record.id.uuidString, "title": "Right"])
        XCTAssertEqual(renamed["title"] as? String, "Right")
        XCTAssertTrue(record.titleIsUserSet)

        let meeting = try object("get_meeting", ["id": record.id.uuidString])
        XCTAssertEqual((meeting["todo_proposals"] as? [Any])?.count, 2)

        let accepted = try object("accept_todo_proposal", ["id": proposal.id.uuidString, "title": "Send the deck"])
        XCTAssertEqual((accepted["todo"] as? JSONObject)?["title"] as? String, "Send the deck")
        XCTAssertTrue(try call("accept_todo_proposal", ["id": proposal.id.uuidString]).isError, "already decided")

        _ = try object("decline_todo_proposal", ["id": other.id.uuidString])
        XCTAssertEqual(other.status, TodoProposal.Status.declined)
        let pending = try XCTUnwrap(try callOK("list_todo_proposals") as? [Any])
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Dates

    func test_datesWithoutAnOffsetAreLocalTime() throws {
        let parsed = try XCTUnwrap(MCPArguments.parseDate("2026-10-09T14:30"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 10, 9, 14, 30])
        XCTAssertNotNil(MCPArguments.parseDate("2026-10-09T14:30:00Z"))
        XCTAssertNotNil(MCPArguments.parseDate("2026-10-09"))
        XCTAssertNil(MCPArguments.parseDate("next tuesday"))
    }

    // MARK: - Socket

    func test_socketRoundTripAndOwnerOnlyPermissions() async throws {
        let path = NSTemporaryDirectory() + "hansel-mcp-\(UUID().uuidString.prefix(8)).sock"
        let server = MCPServer(handler: handler, socketPath: path)
        server.start()
        defer { server.stop() }
        XCTAssertEqual(server.status, .listening)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Off the main thread: the server answers on the main actor.
        let reply: String = try await Task.detached {
            guard let fd = MCPSocket.connect(to: path) else { throw XCTSkip("could not connect") }
            defer { close(fd) }
            let request = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
                + #"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\n"
            MCPSocket.writeAll(fd, Data(request.utf8))
            var first: Data?
            shutdown(fd, SHUT_WR)
            MCPSocket.readLines(fd) { line in if first == nil { first = line } }
            return String(decoding: first ?? Data(), as: UTF8.self)
        }.value
        XCTAssertTrue(reply.contains("\"id\":7"), reply)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(MCPSocket.connect(to: path))
    }
}
