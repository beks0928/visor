import Foundation
import Observation

enum ChatProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, gemini, openai, deepseek, qwen, mistral, groq, xai, openrouter, kimi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .qwen: "Qwen"
        case .mistral: "Mistral"
        case .groq: "Groq"
        case .xai: "Grok (xAI)"
        case .openrouter: "OpenRouter"
        case .kimi: "Kimi"
        }
    }

    /// Имя записи в связке ключей.
    var keyAccount: String { "chat-\(rawValue)" }

    /// Модель по умолчанию. В настройках её можно заменить: названия моделей у сервисов меняются.
    var model: String {
        switch self {
        case .claude: "claude-sonnet-5-5"
        case .gemini: "gemini-2.5-flash"
        case .openai: "gpt-4.1-mini"
        case .deepseek: "deepseek-chat"
        case .qwen: "qwen-plus"
        case .mistral: "mistral-small-latest"
        case .groq: "llama-3.3-70b-versatile"
        case .xai: "grok-3-mini"
        case .openrouter: "openai/gpt-4o-mini"
        case .kimi: "moonshot-v1-8k"
        }
    }

    var keyPage: String {
        switch self {
        case .claude: "https://console.anthropic.com/settings/keys"
        case .gemini: "https://aistudio.google.com/apikey"
        case .openai: "https://platform.openai.com/api-keys"
        case .deepseek: "https://platform.deepseek.com/api_keys"
        case .qwen: "https://bailian.console.alibabacloud.com/?apiKey=1"
        case .mistral: "https://console.mistral.ai/api-keys"
        case .groq: "https://console.groq.com/keys"
        case .xai: "https://console.x.ai"
        case .openrouter: "https://openrouter.ai/keys"
        case .kimi: "https://platform.moonshot.ai/console/api-keys"
        }
    }

    /// Адрес сервиса с интерфейсом, как у OpenAI (`/chat/completions`). nil у Claude и Gemini: у них свой формат.
    var compatibleBase: String? {
        switch self {
        case .claude, .gemini: nil
        case .openai: "https://api.openai.com/v1"
        case .deepseek: "https://api.deepseek.com"
        case .qwen: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .xai: "https://api.x.ai/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .kimi: "https://api.moonshot.ai/v1"
        }
    }

    /// Показываются во вкладке «Чат», пока вы не выбрали другие в настройках.
    static let defaultPinned: [ChatProvider] = [.claude, .gemini, .openai]
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    let text: String
    let date: Date

    init(role: Role, text: String, date: Date = Date()) {
        id = UUID()
        self.role = role
        self.text = text
        self.date = date
    }
}

enum ChatAPI {
    static let system = "Отвечай по-русски, коротко и по делу, если не просят иначе."
    /// Сколько последних сообщений уходит модели как контекст.
    static let contextLimit = 20

    enum Failure: Error, Equatable {
        case key, network
        case api(String)
    }

    static func request(provider: ChatProvider, key: String, messages: [ChatMessage], model modelName: String? = nil) -> URLRequest? {
        let recent = messages.suffix(contextLimit)
        let modelName = (modelName?.isEmpty == false ? modelName : nil) ?? provider.model
        let body: [String: Any]
        let url: URL
        var headers: [String: String] = ["content-type": "application/json"]
        switch provider {
        case .claude:
            guard let endpoint = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
            url = endpoint
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
            body = [
                "model": modelName, "max_tokens": 2048, "system": system,
                "messages": recent.map { ["role": $0.role.rawValue, "content": $0.text] },
            ]
        case .gemini:
            guard let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent") else { return nil }
            url = endpoint
            headers["x-goog-api-key"] = key
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": recent.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] },
            ]
        default:
            // Остальные сервисы принимают запрос в формате OpenAI.
            guard let base = provider.compatibleBase, let endpoint = URL(string: base + "/chat/completions") else { return nil }
            url = endpoint
            headers["authorization"] = "Bearer \(key)"
            var list: [[String: String]] = [["role": "system", "content": system]]
            list += recent.map { ["role": $0.role.rawValue, "content": $0.text] }
            body = ["model": modelName, "messages": list]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.httpBody = data
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    static func parse(provider: ChatProvider, data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let parts: [[String: Any]]
        switch provider {
        case .claude:
            parts = root["content"] as? [[String: Any]] ?? []
        case .gemini:
            let candidate = (root["candidates"] as? [[String: Any]])?.first
            parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        default:
            let choice = (root["choices"] as? [[String: Any]])?.first
            let content = (choice?["message"] as? [String: Any])?["content"] as? String
            return content.flatMap { $0.isEmpty ? nil : $0 }
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    static func errorMessage(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
    }

    static func send(provider: ChatProvider, key: String, messages: [ChatMessage], model: String? = nil, session: URLSession = .shared) async throws -> String {
        guard let request = request(provider: provider, key: key, messages: messages, model: model) else { throw Failure.network }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.network }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.key }
        guard status == 200 else { throw Failure.api(errorMessage(data) ?? "Ошибка \(status)") }
        guard let text = parse(provider: provider, data: data) else { throw Failure.api("Пустой ответ") }
        return text
    }
}

/// Чат с несколькими моделями. Ключи лежат в связке ключей, переписка по каждой модели хранится отдельно.
@MainActor @Observable
final class ChatStore {
    static let shared = ChatStore(directory: VisorPaths.supportDir, defaults: .standard)

    var provider: ChatProvider {
        didSet { defaults.set(provider.rawValue, forKey: "chat.provider") }
    }
    private(set) var conversations: [ChatProvider: [ChatMessage]] = [:]
    /// Модели во вкладке «Чат»: не больше трёх, остальные доступны в настройках.
    private(set) var pinned: [ChatProvider]
    private(set) var keys: Set<ChatProvider>
    private(set) var isSending = false
    private(set) var error: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychainService: String

    init(directory: URL, defaults: UserDefaults, keychainService: String = SecretStore.service) {
        self.directory = directory
        self.defaults = defaults
        self.keychainService = keychainService
        let pins = PinRules.normalize(saved: defaults.stringArray(forKey: "chat.pinned") ?? [], all: ChatProvider.allCases, defaults: ChatProvider.defaultPinned)
        pinned = pins
        let saved = ChatProvider(rawValue: defaults.string(forKey: "chat.provider") ?? "")
        provider = saved.flatMap { pins.contains($0) ? $0 : nil } ?? pins[0]
        keys = Set(ChatProvider.allCases.filter { SecretStore.get($0.keyAccount, service: keychainService) != nil })
        load()
    }

    /// Модель для запросов: своя из настроек или модель по умолчанию.
    func model(for provider: ChatProvider) -> String {
        let custom = defaults.string(forKey: "chat.model.\(provider.rawValue)")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? provider.model : custom
    }

    func setModel(_ name: String, for provider: ChatProvider) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { defaults.removeObject(forKey: "chat.model.\(provider.rawValue)") } else { defaults.set(clean, forKey: "chat.model.\(provider.rawValue)") }
    }

    func setPinned(_ item: ChatProvider, _ on: Bool) {
        pinned = PinRules.toggled(pinned, item, on: on)
        defaults.set(pinned.map(\.rawValue), forKey: "chat.pinned")
        if !pinned.contains(provider) { provider = pinned[0] }
    }

    /// Ключ можно задать для любой модели, не только для открытой во вкладке.
    func saveKey(_ key: String, for target: ChatProvider) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, SecretStore.set(clean, account: target.keyAccount, service: keychainService) else { return }
        keys.insert(target)
        error = nil
    }

    func removeKey(for target: ChatProvider) {
        SecretStore.delete(target.keyAccount, service: keychainService)
        keys.remove(target)
    }

    private var fileURL: URL { directory.appendingPathComponent("chat.json") }

    var messages: [ChatMessage] { conversations[provider] ?? [] }
    var hasKey: Bool { keys.contains(provider) }

    func saveKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, SecretStore.set(clean, account: provider.keyAccount, service: keychainService) else { return }
        keys.insert(provider)
        error = nil
    }

    func removeKey() {
        SecretStore.delete(provider.keyAccount, service: keychainService)
        keys.remove(provider)
    }

    func clear() {
        conversations[provider] = []
        error = nil
        save()
    }

    func send(_ text: String, session: URLSession = .shared) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isSending, let key = SecretStore.get(provider.keyAccount, service: keychainService) else { return }
        let target = provider
        conversations[target, default: []].append(ChatMessage(role: .user, text: clean))
        isSending = true
        error = nil
        defer { isSending = false; save() }
        do {
            let reply = try await ChatAPI.send(provider: target, key: key, messages: conversations[target] ?? [], model: model(for: target), session: session)
            conversations[target, default: []].append(ChatMessage(role: .assistant, text: reply))
        } catch ChatAPI.Failure.key {
            error = "\(target.title) не принял ключ. Вставьте новый."
        } catch ChatAPI.Failure.api(let message) {
            error = "\(target.title): \(message)"
        } catch {
            self.error = "Нет связи с \(target.title)."
        }
    }

    /// Только для снимков и самопроверок.
    func preset(_ messages: [ChatMessage], for provider: ChatProvider) {
        conversations[provider] = messages
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([String: [ChatMessage]].self, from: data) {
            conversations = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                ChatProvider(rawValue: key).map { ($0, value) }
            })
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let raw = Dictionary(uniqueKeysWithValues: conversations.map { ($0.key.rawValue, $0.value) })
        guard let data = try? encoder.encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
