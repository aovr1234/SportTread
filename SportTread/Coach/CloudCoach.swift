import Foundation
import Security

/// One AI service that speaks the OpenAI-style chat format (Groq, Gemini, Cohere, OVHcloud, or a server at
/// home running Ollama). Workouts are tried on each enabled one in order, then on Apple Intelligence, then
/// with the built-in rules.
struct CloudProvider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var needsKey: Bool
    var enabled: Bool
    /// Where to get a key, or what the entry is
    var about: String

    static let defaults: [CloudProvider] = [
        CloudProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b",
                      needsKey: true, enabled: true, about: "Fast and free. Key: console.groq.com/keys"),
        CloudProvider(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                      model: "gemini-3.5-flash-lite", needsKey: true, enabled: true,
                      about: "Strong with structure. Key: aistudio.google.com/apikey. Free-tier prompts may be used by Google."),
        CloudProvider(id: "cohere", name: "Cohere", baseURL: "https://api.cohere.ai/compatibility/v1", model: "command-a-03-2025",
                      needsKey: true, enabled: true, about: "Free trial key, 1,000 calls a month. Key: dashboard.cohere.com/api-keys"),
        CloudProvider(id: "ovh", name: "OVHcloud", baseURL: "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1", model: "gpt-oss-120b",
                      needsKey: false, enabled: true, about: "No key needed, EU-hosted, slow (30 to 45 s) and limited to 2 requests a minute."),
        CloudProvider(id: "home", name: "Home server (Ollama)", baseURL: "http://192.168.1.50:11434/v1", model: "qwen3:8b",
                      needsKey: false, enabled: false, about: "Your own server on the home network. Change the address to yours."),
    ]
}

/// API keys live in the iPhone's Keychain, never in the app's files or the diagnostics log.
enum KeychainStore {
    private static let service = "SportTreadCloud"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        delete(account)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The Setup choices for cloud AI. Off until the user turns it on.
@MainActor
final class CloudSettings: ObservableObject {
    static let shared = CloudSettings()

    @Published var useCloud: Bool { didSet { UserDefaults.standard.set(useCloud, forKey: Self.useKey) } }
    /// Send recent workouts and the readiness line along with the request (on by default)
    @Published var sendHistory: Bool { didSet { UserDefaults.standard.set(sendHistory, forKey: Self.historyKey) } }
    @Published var providers: [CloudProvider] { didSet { save() } }
    /// Bumped when a key is saved, so screens that show "key saved" refresh
    @Published private(set) var keyVersion = 0

    private static let useKey = "cloudAIOn"
    private static let historyKey = "cloudSendHistory"
    private static let providersKey = "cloudProviders"

    private init() {
        let defaults = UserDefaults.standard
        useCloud = defaults.bool(forKey: Self.useKey)
        sendHistory = defaults.object(forKey: Self.historyKey) == nil ? true : defaults.bool(forKey: Self.historyKey)
        var stored = (defaults.data(forKey: Self.providersKey)).flatMap { try? JSONDecoder().decode([CloudProvider].self, from: $0) } ?? []
        // The old default Gemini model name (only that one) moves to the model that exists on the free tier
        for index in stored.indices where stored[index].id == "gemini" && stored[index].model == "gemini-2.5-flash" {
            stored[index].model = "gemini-3.5-flash-lite"
        }
        // Providers added in later builds appear at the end
        for preset in CloudProvider.defaults where !stored.contains(where: { $0.id == preset.id }) { stored.append(preset) }
        providers = stored
    }

    private func save() {
        if let data = try? JSONEncoder().encode(providers) { UserDefaults.standard.set(data, forKey: Self.providersKey) }
    }

    func key(for id: String) -> String? { KeychainStore.get("key-" + id) }

    func hasKey(_ id: String) -> Bool { !(key(for: id) ?? "").isEmpty }

    func setKey(_ key: String, for id: String) {
        KeychainStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: "key-" + id)
        keyVersion += 1
    }

    /// Enabled providers that can be used right now, in order.
    var ready: [CloudProvider] {
        guard useCloud else { return [] }
        return providers.filter { $0.enabled && (!$0.needsKey || hasKey($0.id)) }
    }

    /// A tiny request to check the address, the key and the model.
    func test(_ provider: CloudProvider) async -> String {
        let key = key(for: provider.id)
        if provider.needsKey, (key ?? "").isEmpty { return "Add a key first." }
        do {
            let reply = try await CloudClient.chat(
                provider: provider, key: key,
                messages: [["role": "system", "content": "Reply with the single word OK."], ["role": "user", "content": "Test"]],
                maxTokens: 800, timeout: 60)
            return String(format: "Works (%.1f s). It said: %@", reply.seconds, String(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)))
        } catch {
            return error.localizedDescription
        }
    }
}

enum CloudClient {
    struct Reply {
        let text: String
        let seconds: Double
    }

    enum Failure: LocalizedError {
        case keyRejected, rateLimited, http(Int, String), network(String), badReply

        var errorDescription: String? {
            switch self {
            case .keyRejected: "The key was rejected."
            case .rateLimited: "Too many requests right now (free limit reached)."
            case .http(let code, let body): "The server answered \(code): \(body)"
            case .network(let text): "Couldn't reach it: \(text)"
            case .badReply: "The answer wasn't in the expected format."
            }
        }
    }

    /// One chat request. Works with anything that offers `/chat/completions` in the OpenAI style.
    static func chat(provider: CloudProvider, key: String?, messages: [[String: String]],
                     maxTokens: Int = 5000, timeout: TimeInterval = 90) async throws -> Reply {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else { throw Failure.network("the address isn't valid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": provider.model, "messages": messages, "temperature": 0.4, "max_tokens": maxTokens]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        var result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.keyRejected }
        if status == 429 { throw Failure.rateLimited }
        guard (200..<300).contains(status) else {
            throw Failure.http(status, String(String(data: data, encoding: .utf8)?.prefix(160) ?? ""))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw Failure.badReply }
        return Reply(text: text, seconds: Date().timeIntervalSince(started))
    }
}
