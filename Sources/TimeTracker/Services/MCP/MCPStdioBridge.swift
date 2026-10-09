import Foundation

/// `Hansel --mcp-stdio`: what assistants launch to talk to Hansel.
///
/// Every MCP client on the Mac (Claude Desktop, Claude Code, Codex, Cursor) can start a
/// local server as a process and talk to it over stdin and stdout. This process holds
/// no data: it relays each line to the running app's socket and each reply back. When
/// the app is not reachable it answers requests with an error saying what to do, and
/// it reconnects on the next message, so starting Hansel later just works.
enum MCPStdioBridge {

    static let flag = "--mcp-stdio"

    static let unavailableMessage = "Hansel is not reachable. Open Hansel and turn on Settings → Integrations → Allow AI assistants on this Mac."

    static func run(socketPath: String = MCPSocket.defaultPath) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let relay = Relay(socketPath: socketPath)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            relay.forward(Data(line.utf8))
        }
        relay.close()
        exit(0)
    }

    /// The connection to the app, reopened as needed, and stdout shared by the
    /// reader thread and the error replies.
    final class Relay: @unchecked Sendable {
        private let socketPath: String
        private let lock = NSLock()
        private let outputLock = NSLock()
        private var fd: Int32 = -1

        init(socketPath: String) {
            self.socketPath = socketPath
        }

        func forward(_ message: Data) {
            var line = message
            line.append(0x0A)
            for _ in 0..<2 {
                guard let fd = connection() else { break }
                if MCPSocket.writeAll(fd, line) { return }
                drop(fd)
            }
            replyUnavailable(to: message)
        }

        func close() {
            lock.withLock {
                if fd >= 0 { Darwin.close(fd) }
                fd = -1
            }
        }

        private func connection() -> Int32? {
            lock.withLock {
                if fd >= 0 { return fd }
                guard let opened = MCPSocket.connect(to: socketPath) else { return nil }
                fd = opened
                Thread.detachNewThread { [self] in
                    MCPSocket.readLines(opened) { reply in self.write(reply) }
                    self.drop(opened)
                }
                return opened
            }
        }

        private func drop(_ dropped: Int32) {
            lock.withLock {
                guard fd == dropped else { return }
                Darwin.close(dropped)
                fd = -1
            }
        }

        private func replyUnavailable(to message: Data) {
            // Notifications get no reply, even an error.
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                  let id = object["id"], object["method"] != nil else { return }
            let reply: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32000, "message": MCPStdioBridge.unavailableMessage],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: reply) { write(data) }
        }

        private func write(_ line: Data) {
            var data = line
            data.append(0x0A)
            outputLock.withLock { _ = MCPSocket.writeAll(STDOUT_FILENO, data) }
        }
    }
}
