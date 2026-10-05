import Foundation

struct AnthropicProvider: AIProvider {
    let id: UUID
    let displayName: String
    let model: String
    let apiKey: String
    var baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    var session: URLSession = .shared

    /// What the configured model accepts. The model id is free text in Settings, so
    /// parameters newer models need (or reject) are sent only where they apply.
    struct ModelTraits: Equatable {
        /// `output_config.effort` — current Opus/Sonnet/Fable generations.
        let supportsEffort: Bool
        /// Server-side refusal fallback (`fallbacks: "default"`).
        let supportsDefaultFallback: Bool

        init(model: String) {
            let m = model.lowercased()
            let effortPrefixes = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5",
                                  "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6"]
            supportsEffort = effortPrefixes.contains { m.hasPrefix($0) }
            let fallbackModels = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
            supportsDefaultFallback = fallbackModels.contains(m)
        }
    }

    func requestBody(system: String, user: String, maxTokens: Int, effort: AIEffort = .low) -> [String: Any] {
        let traits = ModelTraits(model: model)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        // Short classification calls: low effort for routine drafts, a step up for the
        // task-switch decision. Thinking stays well inside max_tokens either way.
        if traits.supportsEffort { body["output_config"] = ["effort": effort.rawValue] }
        // A safety classifier declining an ordinary work log should not lose the
        // answer: let the API retry on the recommended model for that category.
        if traits.supportsDefaultFallback { body["fallbacks"] = "default" }
        return body
    }

    func complete(system: String, user: String, maxTokens: Int, effort: AIEffort) async throws -> String {
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if ModelTraits(model: model).supportsDefaultFallback {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(system: system, user: user, maxTokens: maxTokens, effort: effort)
        )

        let t0 = Date()
        let (data, http) = try await AIHTTP.send(req, session: session, label: "anthropic")
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        guard http.statusCode == 200 else {
            let excerpt = AIHTTP.excerpt(data)
            AppLogger.ai.error("anthropic status=\(http.statusCode) body=\(excerpt, privacy: .private)")
            AppLogger.log("ai", level: .error, "anthropic status=\(http.statusCode) latency=\(latencyMs)ms")
            throw AIError.badStatus(http.statusCode, excerpt)
        }
        let text = try Self.extractText(from: data)
        AppLogger.ai.info("anthropic ok model=\(model, privacy: .public) latency=\(latencyMs)ms bytes=\(data.count)")
        AppLogger.log("ai", level: .info, "anthropic ok model=\(model) latency=\(latencyMs)ms")
        return text
    }

    /// The answer text, after checking why the model stopped. A refusal or a cut-off
    /// response must surface as its own error, not as "empty" or "unparseable".
    static func extractText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parseFailed("response is not a JSON object")
        }
        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw AIError.refused(details?["category"] as? String)
        }
        // Only `text` blocks carry the answer; thinking and fallback blocks do not.
        let content = (json["content"] as? [[String: Any]]) ?? []
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        if stopReason == "max_tokens" { throw AIError.truncated }
        guard !text.isEmpty else {
            AppLogger.ai.error("anthropic empty response")
            throw AIError.emptyResponse
        }
        return text
    }
}
