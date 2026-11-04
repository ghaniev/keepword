import Foundation

/// One client for every provider: Ollama / LM Studio locally, or OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek
/// in the cloud. All of them speak `POST {base}/chat/completions`.
struct LLM {
    var baseURL: String
    var model: String
    var apiKey: String

    /// Transcript characters that fit one request: local models are bounded by their context window
    /// (~3.5 chars per token, room left for instructions and the answer); cloud models get 60k.
    var maxInputChars: Int {
        let debug = UserDefaults.standard.integer(forKey: "debugMaxInputChars")  // launch-argument override for testing map-reduce
        if debug > 0 { return debug }
        guard baseURL == LocalModels.providerURL, let m = LocalModels.find(model) else { return 60_000 }
        return Int(Double(m.contextTokens - 5_000) * 3.5)
    }

    static var current: LLM {
        let d = UserDefaults.standard
        return LLM(baseURL: d.string(forKey: "llmBaseURL") ?? "http://localhost:11434/v1",
                   model: d.string(forKey: "llmModel") ?? "qwen3:8b",
                   apiKey: Keychain.get("llmAPIKey"))
    }

    /// Embeddings may come from a different endpoint (Anthropic has none). Empty model disables semantic search.
    static var embedder: LLM? {
        let d = UserDefaults.standard
        let model = d.string(forKey: "embeddingModel") ?? "bge-m3"
        guard !model.isEmpty else { return nil }
        let base = d.string(forKey: "embeddingBaseURL").flatMap { $0.isEmpty ? nil : $0 } ?? current.baseURL
        guard !base.hasPrefix("cli:") else { return nil }  // CLIs have no embeddings: keyword search only
        return LLM(baseURL: base, model: model, apiKey: Keychain.get(base == current.baseURL ? "llmAPIKey" : "embeddingAPIKey"))
    }

    private func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 900)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpMethod = "POST"
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError(message: "AI provider error \((response as? HTTPURLResponse)?.statusCode ?? 0): "
                           + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    func chat(system: String, user: String) async throws -> String {
        try await chat(messages: [["role": "system", "content": system], ["role": "user", "content": user]])
    }

    func chat(messages: [[String: String]]) async throws -> String {
        try Self.visibleAnswer(try await rawChat(messages))
    }

    private func rawChat(_ messages: [[String: String]]) async throws -> String {
        if baseURL == LocalModels.providerURL {
            guard let m = LocalModels.find(model) ?? LocalModels.catalog.first(where: \.isDownloaded) else {
                throw LLMError(message: "No local model downloaded. Open Settings → AI Provider.")
            }
            return try await LlamaEngine.shared.generate(m, messages: messages)
        }
        if baseURL.hasPrefix("cli:") {
            return try await CLIProvider.chat(tool: String(baseURL.dropFirst(4)), model: model, messages: messages)
        }
        let data = try await send(request("/chat/completions", body: ["model": model, "temperature": 0.2, "messages": messages]))
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        return try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content ?? ""
    }

    /// Reasoning models (Qwen3, DeepSeek-R1…) wrap their thinking in <think>/<thinking>. Drop it, including an
    /// unterminated block left when the answer hit the token limit (as Meetily does), and refuse reasoning-only replies.
    static func visibleAnswer(_ raw: String) throws -> String {
        var text = raw.replacingOccurrences(of: #"(?is)<think(?:ing)?(?:\s[^>]*)?>.*?</think(?:ing)?\s*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<think(?:ing)?(?:\s[^>]*)?>.*$"#, with: "", options: .regularExpression)  // unterminated
        text = text.replacingOccurrences(of: #"(?i)</think(?:ing)?\s*>"#, with: "", options: .regularExpression)  // stray closer
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LLMError(message: raw.range(of: "<think", options: .caseInsensitive) != nil
                ? "The AI only produced reasoning and no answer (it may have hit its output limit). Try again or use a larger model."
                : "The AI returned an empty response.")
        }
        return text
    }

    /// Asks for JSON and decodes the first JSON object/array found in the reply (models love code fences).
    func json<T: Decodable>(_ type: T.Type, system: String, user: String) async throws -> T {
        let reply = try await chat(system: system, user: user)
        guard let a = reply.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let b = reply.lastIndex(of: reply[a] == "[" ? "]" : "}"), a < b else {
            throw LLMError(message: "No JSON in reply: \(reply.prefix(200))")
        }
        return try JSONDecoder().decode(T.self, from: Data(reply[a...b].utf8))
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let data = try await send(request("/embeddings", body: ["model": model, "input": texts]))
        struct Reply: Decodable { struct Item: Decodable { let embedding: [Float]; let index: Int? }; let data: [Item] }
        let items = try JSONDecoder().decode(Reply.self, from: data).data
        return items.enumerated().sorted { ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset) }.map(\.element.embedding)
    }

    func models() async throws -> [String] {
        struct Reply: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        return try JSONDecoder().decode(Reply.self, from: try await send(request("/models"))).data.map(\.id).sorted()
    }
}

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
