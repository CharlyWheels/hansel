import Foundation

struct AIProviderConfig: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case anthropic
        case openAICompatible
        var id: String { rawValue }
        var label: String {
            switch self {
            case .anthropic: return "Anthropic (Claude)"
            case .openAICompatible: return "OpenAI-compatible (GPT / Kimi / Ollama / LM-Studio)"
            }
        }
    }

    var id: UUID
    var name: String            // user label, e.g. "Claude Opus"
    var kind: Kind
    var baseURL: String?        // required for openAICompatible
    var model: String           // e.g. "claude-opus-4-7", "gpt-4o-mini", "moonshot-v1-32k"
    var isDefault: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        baseURL: String? = nil,
        model: String,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.isDefault = isDefault
    }

    static let presets: [AIProviderConfig] = [
        AIProviderConfig(name: "Claude", kind: .anthropic, model: "claude-opus-4-7"),
        AIProviderConfig(name: "OpenAI GPT", kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        AIProviderConfig(name: "Kimi (Moonshot)", kind: .openAICompatible, baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-32k"),
        AIProviderConfig(name: "Local (Ollama)", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "xiaomi-mimo")
    ]
}

enum AISettingsStore {
    private static let providersKey = "ai.providers"
    private static let contextFieldsKey = "ai.contextFields"

    static func loadProviders() -> [AIProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: providersKey),
              let decoded = try? JSONDecoder().decode([AIProviderConfig].self, from: data) else { return [] }
        return decoded
    }
    static func saveProviders(_ providers: [AIProviderConfig]) {
        let data = (try? JSONEncoder().encode(providers)) ?? Data()
        UserDefaults.standard.set(data, forKey: providersKey)
    }
    static func loadContextFields() -> ContextFieldSelection {
        guard let data = UserDefaults.standard.data(forKey: contextFieldsKey),
              let decoded = try? JSONDecoder().decode(ContextFieldSelection.self, from: data) else { return ContextFieldSelection() }
        return decoded
    }
    static func saveContextFields(_ selection: ContextFieldSelection) {
        let data = (try? JSONEncoder().encode(selection)) ?? Data()
        UserDefaults.standard.set(data, forKey: contextFieldsKey)
    }

    static func keychainKey(for id: UUID) -> String { "ai.provider.\(id.uuidString).key" }
}

enum ProviderRegistry {
    static func build(_ config: AIProviderConfig) -> AIProvider? {
        let apiKey = KeychainStore.get(AISettingsStore.keychainKey(for: config.id)) ?? ""
        switch config.kind {
        case .anthropic:
            return AnthropicProvider(id: config.id, displayName: config.name, model: config.model, apiKey: apiKey)
        case .openAICompatible:
            guard let s = config.baseURL, let url = URL(string: s) else { return nil }
            return OpenAICompatibleProvider(id: config.id, displayName: config.name, baseURL: url, model: config.model, apiKey: apiKey)
        }
    }

    static func defaultProvider() -> AIProvider? {
        let configs = AISettingsStore.loadProviders()
        guard let config = configs.first(where: { $0.isDefault }) ?? configs.first else { return nil }
        return build(config)
    }
}
