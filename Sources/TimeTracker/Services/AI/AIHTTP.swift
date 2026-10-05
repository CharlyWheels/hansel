import Foundation

/// The HTTP plumbing both providers share: a hard deadline, and one retry for the
/// failures that are worth retrying (rate limits, overload, server errors).
enum AIHTTP {
    /// A boundary question is only useful while it is still about "now"; a request
    /// that takes minutes produces a question about the past.
    static let requestTimeout: TimeInterval = 30
    /// Never wait longer than this for a `retry-after`, for the same reason.
    static let maxRetryDelay: TimeInterval = 10

    static func send(
        _ request: URLRequest,
        session: URLSession,
        label: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = requestTimeout
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.badStatus(0, "no HTTP response")
            }
            let retryable = http.statusCode == 429 || http.statusCode == 529 || (500...599).contains(http.statusCode)
            guard retryable, attempt == 1 else { return (data, http) }
            let delay = retryDelay(http)
            AppLogger.log("ai", level: .notice, "\(label) retry status=\(http.statusCode) delay=\(delay)s")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private static func retryDelay(_ response: HTTPURLResponse) -> TimeInterval {
        if let raw = response.value(forHTTPHeaderField: "retry-after"), let seconds = Double(raw) {
            return min(max(seconds, 0.5), maxRetryDelay)
        }
        return 2
    }

    /// Error bodies can echo parts of the prompt, so keep them short in the logs.
    static func excerpt(_ data: Data) -> String {
        String((String(data: data, encoding: .utf8) ?? "").prefix(300))
    }
}
