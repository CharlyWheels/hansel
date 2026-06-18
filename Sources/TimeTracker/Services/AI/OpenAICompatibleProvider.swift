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

    func draft(_ context: SuggestionContext) async throws -> EntryDraft {
        let (system, user) = PromptBuilder.build(context: context)
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
            "response_format": ["type": "json_object"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status != 200 {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            AppLogger.ai.error("oai \(url.host ?? "") status=\(status)")
            AppLogger.log("ai", level: .error, "oai host=\(url.host ?? "") status=\(status) body=\(bodyText.prefix(200))")
            throw AIError.badStatus(status, bodyText)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = (json?["choices"] as? [[String: Any]]) ?? []
        let message = choices.first?["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""
        guard !text.isEmpty else {
            AppLogger.ai.error("oai \(url.host ?? "") empty response")
            throw AIError.emptyResponse
        }
        AppLogger.ai.info("oai ok host=\(url.host ?? "", privacy: .public) model=\(model, privacy: .public) latency=\(latencyMs)ms")
        AppLogger.log("ai", level: .info, "oai ok host=\(url.host ?? "") model=\(model) latency=\(latencyMs)ms")
        return try DraftParser.parse(text, context: context, providerLabel: "\(displayName) \(model)")
    }
}
