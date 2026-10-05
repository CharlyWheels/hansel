import Foundation

/// Works with any OpenAI-compatible `/v1/chat/completions` endpoint:
/// OpenAI, Kimi (Moonshot), Ollama / LM-Studio (for Xiaomi MiMo and other local models),
/// Mistral-compatible gateways, etc.
struct OpenAICompatibleProvider: AIProvider {
    let id: UUID
    let displayName: String
    let baseURL: URL     // e.g. https://api.openai.com/v1
    let model: String
    let apiKey: String
    var session: URLSession = .shared

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let url = baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let t0 = Date()
        let (data, http) = try await AIHTTP.send(req, session: session, label: "oai")
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        let status = http.statusCode
        if status != 200 {
            let excerpt = AIHTTP.excerpt(data)
            AppLogger.ai.error("oai \(url.host ?? "") status=\(status)")
            AppLogger.log("ai", level: .error, "oai host=\(url.host ?? "") status=\(status)")
            throw AIError.badStatus(status, excerpt)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parseFailed("response is not a JSON object")
        }
        let choices = (json["choices"] as? [[String: Any]]) ?? []
        let message = choices.first?["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""
        if choices.first?["finish_reason"] as? String == "length" { throw AIError.truncated }
        guard !text.isEmpty else {
            AppLogger.ai.error("oai \(url.host ?? "") empty response")
            throw AIError.emptyResponse
        }
        AppLogger.ai.info("oai ok host=\(url.host ?? "", privacy: .public) model=\(model, privacy: .public) latency=\(latencyMs)ms")
        AppLogger.log("ai", level: .info, "oai ok host=\(url.host ?? "") model=\(model) latency=\(latencyMs)ms")
        return text
    }
}
