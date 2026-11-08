import SwiftUI

struct AIProviderSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("llmBaseURL") private var baseURL = "http://localhost:11434/v1"
    @AppStorage("llmModel") private var llmModel = "qwen3:8b"
    @AppStorage("embeddingModel") private var embeddingModel = "bge-m3"
    @AppStorage("embeddingBaseURL") private var embeddingBaseURL = ""
    @AppStorage("embeddingSource") private var embeddingSource = "local"
    @State private var apiKey = Keychain.get("llmAPIKey")
    @State private var embeddingKey = Keychain.get("embeddingAPIKey")
    @State private var models: [String] = []
    @State private var testResult = ""
    @State private var testing = false

    static let presets = [
        ("On this Mac — built-in Qwen (llama.cpp)", LocalModels.providerURL),
        ("ChatGPT subscription (Codex CLI)", "cli:codex"), ("Claude subscription (Claude Code CLI)", "cli:claude"),
        ("Ollama (local)", "http://localhost:11434/v1"), ("LM Studio (local)", "http://localhost:1234/v1"),
        ("OpenAI", "https://api.openai.com/v1"), ("Anthropic", "https://api.anthropic.com/v1"),
        ("Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
        ("OpenRouter", "https://openrouter.ai/api/v1"), ("DeepSeek", "https://api.deepseek.com"),
    ]

    var body: some View {
        Form {
            Section("Language Model") {
                Picker("Provider", selection: $baseURL) {
                    ForEach(Self.presets, id: \.1) { Text($0.0).tag($0.1) }
                    if !Self.presets.contains(where: { $0.1 == baseURL }) { Text("Custom").tag(baseURL) }
                }
                if baseURL == LocalModels.providerURL {
                    LocalAIPicker(downloader: model.downloader).padding(.vertical, 6)
                } else if let tool = cliTool {
                    LabeledContent("CLI") {
                        Text(CLIProvider.locate(tool)?.path ?? String(localized: "Not found — install it or set the path below"))
                            .foregroundStyle(CLIProvider.locate(tool) == nil ? .red : .secondary).lineLimit(1).truncationMode(.middle)
                    }
                    TextField("Custom path (optional)", text: Binding(get: { UserDefaults.standard.string(forKey: "cliPath_\(tool)") ?? "" },
                                                                       set: { UserDefaults.standard.set($0, forKey: "cliPath_\(tool)") }))
                    TextField("Model", text: $llmModel, prompt: Text(CLIProvider.defaultModel[tool] ?? ""))
                    Text("Uses your existing \(tool == "codex" ? "ChatGPT" : "Claude") sign-in — no API key. If calls fail with an auth error, run `\(CLIProvider.loginHint[tool] ?? tool)` in Terminal. Each call takes a few seconds longer than an API. Semantic search needs a separate embedding server below; otherwise keyword search is used.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Server URL", text: $baseURL)
                    HStack {
                        TextField("Model", text: $llmModel)
                        if !models.isEmpty {
                            Menu("Select Model") { ForEach(models, id: \.self) { m in Button(m) { llmModel = m } } }.fixedSize()
                        }
                        Button("Refresh Models") { Task { models = (try? await LLM.current.models()) ?? [] } }
                    }
                    SecureField("API key (stored in Keychain)", text: $apiKey).onChange(of: apiKey) { Keychain.set("llmAPIKey", $1) }
                }
                HStack {
                    Button("Test Connection") { test() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red).lineLimit(2)
                }
                Text(baseURL == LocalModels.providerURL ? "Local: transcripts never leave this Mac." : cliTool != nil ? "Cloud: transcripts are sent to \(cliTool == "codex" ? "OpenAI" : "Anthropic") through the CLI." : baseURL.contains("localhost") || baseURL.contains("127.0.0.1")
                     ? "Local: nothing leaves this Mac. For Ollama, start it with OLLAMA_CONTEXT_LENGTH=32768 so long meetings fit."
                     : "Cloud: transcripts are sent to this provider for summaries and chat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Semantic Search (embeddings)") {
                Picker("Embeddings", selection: $embeddingSource) {
                    Text("Built-in model (on this Mac)").tag("local")
                    Text("Embedding server").tag("server")
                    Text("Off — keyword search only").tag("off")
                }
                .onChange(of: embeddingSource) { model.reindexAll(); model.toast = String(localized: "Reindexing meetings…") }
                switch embeddingSource {
                case "local":
                    Text("paraphrase-multilingual-MiniLM-L12-v2: 50+ languages including Russian, runs on this Mac, no key. Downloaded once (~470 MB) into the Keepword library.")
                        .font(.caption).foregroundStyle(.secondary)
                case "server":
                    TextField("Embedding model", text: $embeddingModel)
                    TextField("Embedding server URL (empty = same as above)", text: $embeddingBaseURL)
                    if !embeddingBaseURL.isEmpty && embeddingBaseURL != baseURL {
                        SecureField("Embedding API key", text: $embeddingKey).onChange(of: embeddingKey) { Keychain.set("embeddingAPIKey", $1) }
                    }
                    Text("Ollama: `ollama pull bge-m3`. OpenAI: text-embedding-3-small. CLI providers and Anthropic have no embeddings.")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    Text("Search matches words only; Related meetings and chat across meetings get weaker.").font(.caption).foregroundStyle(.secondary)
                }
                Button(String(localized: "Reindex All Meetings")) { model.reindexAll(); model.toast = String(localized: "Reindexing meetings…") }
            }
        }
        .formStyle(.grouped)
        .onChange(of: baseURL) { _, new in
            // Model names differ per provider; offer a working default when switching to a CLI.
            if new.hasPrefix("cli:") { llmModel = CLIProvider.defaultModel[String(new.dropFirst(4))] ?? "" }
            if new == LocalModels.providerURL, LocalModels.find(llmModel) == nil {
                llmModel = (LocalModels.catalog.first(where: \.isDownloaded) ?? LocalModels.recommended).id
            }
        }
    }

    private var cliTool: String? { baseURL.hasPrefix("cli:") ? String(baseURL.dropFirst(4)) : nil }

    private func test() {
        testing = true
        testResult = ""
        Task {
            do {
                let reply = try await LLM.current.chat(system: "Reply with the single word OK.", user: "ping")
                testResult = String(localized: "✓ Connected — \(reply.prefix(40))")
            } catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}
