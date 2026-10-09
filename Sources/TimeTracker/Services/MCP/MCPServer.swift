import Foundation
import Observation

/// Where the app listens for assistants, shared by the app and `Hansel --mcp-stdio`.
enum MCPSocket {
    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "TimeTracker/mcp.sock").path
    }

    /// A `sockaddr_un` for `path`, or nil when the path is too long for one.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        return address
    }

    /// Connects to the app. Returns the descriptor, or nil when nothing is listening.
    static func connect(to path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        noSigPipe(fd)
        return fd
    }

    /// A peer that went away must not kill the process with SIGPIPE.
    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`. False once the peer is gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Reads newline-delimited messages until the peer closes, calling `onLine` for each.
    static func readLines(_ fd: Int32, maxLine: Int = 16 << 20, onLine: (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { onLine(Data(line)) }
            }
            guard buffer.count <= maxLine else { return }
        }
    }
}

/// Lets assistants on this Mac use Hansel through MCP.
///
/// Listens on a Unix socket in the app's support folder that only this user can open,
/// so there is no network port and nothing a web page could reach. Assistants run
/// `Hansel --mcp-stdio`, which relays their messages here. Off until the user turns it
/// on in Settings → Integrations.
@Observable
@MainActor
final class MCPServer {

    enum Status: Equatable {
        case off
        case listening
        case failed(String)
    }

    static let enabledKey = "mcp.enabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private(set) var status: Status = .off

    let socketPath: String
    @ObservationIgnored private let handler: MCPHandler
    @ObservationIgnored private var listenFD: Int32 = -1
    @ObservationIgnored private var acceptSource: DispatchSourceRead?
    @ObservationIgnored private let connections = ConnectionSet()

    init(handler: MCPHandler, socketPath: String = MCPSocket.defaultPath) {
        self.handler = handler
        self.socketPath = socketPath
    }

    /// Starts or stops to match the setting.
    func applySetting() {
        if Self.isEnabled { start() } else { stop() }
    }

    func start() {
        guard listenFD < 0 else { return }
        guard var address = MCPSocket.address(socketPath) else {
            return fail("The socket path is too long: \(socketPath)")
        }
        try? FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        // Left behind by a crash; only one Hansel runs at a time.
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail("socket: \(String(cString: strerror(errno)))") }
        // Owner-only from the moment it exists, not after a chmod.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            return fail("bind: \(reason)")
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            unlink(socketPath)
            return fail("listen: \(reason)")
        }
        listenFD = fd

        let handler = self.handler
        let connections = self.connections
        // Each message is answered on the main actor, where the models live; the
        // connection's own thread waits for it, so replies keep their order.
        let respond: @Sendable (Data) -> Data? = { line in
            DispatchQueue.main.sync { MainActor.assumeIsolated { handler.handle(line) } }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            MCPSocket.noSigPipe(client)
            connections.insert(client)
            Thread.detachNewThread {
                MCPSocket.readLines(client) { line in
                    guard var reply = respond(line) else { return }
                    reply.append(0x0A)
                    MCPSocket.writeAll(client, reply)
                }
                connections.remove(client)
                close(client)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        status = .listening
        AppLogger.log("mcp", level: .info, "listening")
    }

    func stop() {
        guard listenFD >= 0 else {
            if case .failed = status { status = .off }
            return
        }
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        connections.closeAll()
        unlink(socketPath)
        status = .off
        AppLogger.log("mcp", level: .info, "stopped")
    }

    private func fail(_ reason: String) {
        status = .failed(reason)
        AppLogger.log("mcp", level: .error, "start_failed: \(reason)")
    }

    /// Open connections, so stopping the server also drops the assistants on it.
    private final class ConnectionSet: @unchecked Sendable {
        private let lock = NSLock()
        private var fds: Set<Int32> = []

        func insert(_ fd: Int32) { lock.withLock { _ = fds.insert(fd) } }
        func remove(_ fd: Int32) { lock.withLock { _ = fds.remove(fd) } }
        /// Shuts them down; each connection's thread then closes its own descriptor.
        func closeAll() { lock.withLock { fds.forEach { shutdown($0, SHUT_RDWR) } } }
    }
}
