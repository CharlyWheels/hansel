import Foundation

/// A JSON object as `JSONSerialization` reads and writes it.
typealias JSONObject = [String: Any]

/// Answers MCP's JSON-RPC messages: the handshake, and listing and calling tools.
///
/// Stateless on purpose. Every message stands alone, so a bridge that reconnects after
/// Hansel restarts carries on without a new handshake.
@MainActor
final class MCPHandler {

    /// Newest first. The client's version is echoed back when supported.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let tools: MCPTools

    init(tools: MCPTools) {
        self.tools = tools
    }

    /// One line in, at most one line out. Nil for notifications and responses, which
    /// get no reply.
    func handle(_ data: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = parsed as? [Any] {
            let replies = batch.compactMap { handle(message: $0) }
            return replies.isEmpty ? nil : encode(replies)
        }
        return handle(message: parsed).flatMap(encode)
    }

    private func handle(message: Any) -> JSONObject? {
        guard let message = message as? JSONObject, let method = message["method"] as? String else {
            // A response to something we never send, or not JSON-RPC at all.
            if let object = message as? JSONObject, object["id"] != nil, object["result"] == nil, object["error"] == nil {
                return Self.error(id: object["id"]!, code: -32600, message: "Invalid request")
            }
            return nil
        }
        // Notifications (no id) never get a reply.
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? JSONObject ?? [:]

        switch method {
        case "initialize":
            return Self.result(id: id, initialize(params))
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": tools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            guard tools.has(name) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] as? JSONObject ?? [:]
            return Self.result(id: id, tools.call(name, arguments: arguments))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ params: JSONObject) -> JSONObject {
        let requested = params["protocolVersion"] as? String ?? ""
        let version = Self.supportedProtocolVersions.contains(requested)
            ? requested : Self.supportedProtocolVersions[0]
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "hansel", "title": "Hansel", "version": appVersion],
            "instructions": Self.instructions,
        ]
    }

    static let instructions = """
    Hansel is the user's time tracker on this Mac. Use it to answer questions about \
    how they spent their time and to keep their entries, timer and todos up to date. \
    Times are ISO 8601; without an offset they are read as the Mac's local time. \
    Projects, customers, roles and todos can be given by id or by name. \
    Nothing can be deleted through these tools; ask the user to do that in Hansel.
    """

    // MARK: - JSON-RPC envelopes

    static func result(id: Any, _ result: JSONObject) -> JSONObject {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any, code: Int, message: String) -> JSONObject {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
    }
}
