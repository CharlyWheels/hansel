import Foundation

struct AnthropicProvider: AIProvider {
    let id: UUID
    let displayName: String
    let model: String
    let apiKey: String
    var baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!

    func draft(_ context: SuggestionContext) async throws -> EntryDraft {
        let (system, user) = PromptBuilder.build(context: context)
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status != 200 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            AppLogger.ai.error("anthropic status=\(status) body=\(bodyText, privacy: .public)")
            AppLogger.log("ai", level: .error, "anthropic status=\(status) latency=\(latencyMs)ms")
            throw AIError.badStatus(status, bodyText)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (json?["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else {
            AppLogger.ai.error("anthropic empty response")
            throw AIError.emptyResponse
        }
        AppLogger.ai.info("anthropic ok model=\(model, privacy: .public) latency=\(latencyMs)ms bytes=\(data.count)")
        AppLogger.log("ai", level: .info, "anthropic ok model=\(model) latency=\(latencyMs)ms")
        return try DraftParser.parse(text, context: context, providerLabel: "Claude \(model)")
    }
}
