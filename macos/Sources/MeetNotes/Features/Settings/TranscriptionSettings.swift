import SwiftUI

struct TranscriptionSettings: View {
    @AppStorage("diarization") private var diarization = true
    @AppStorage("identifySpeakersFirst") private var identifyFirst = false
    @AppStorage("voiceMatchThreshold") private var threshold = 0.7
    @AppStorage("aiCleanup") private var cleanup = true
    @AppStorage("cleanupPrompt") private var cleanupPrompt = ""
    @AppStorage("transcriptionEngine") private var engine = "local"
    @AppStorage("transcriptionLanguage") private var language = TranscriptionLanguage.defaultCode
    @AppStorage("transcriptionFallbackLocal") private var fallback = true
    // Per-provider fields (empty = the provider's default), reloaded when the engine changes.
    @State private var baseURL = ""
    @State private var cloudModel = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var checkResult: (ok: Bool, text: String)?

    private var provider: CloudTranscriber.Provider? { .init(rawValue: engine) }

    var body: some View {
        Form {
            Section("Speech Recognition") {
                Picker("Engine", selection: $engine) {
                    Text("On this Mac").tag("local")
                    ForEach(CloudTranscriber.Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if let provider {
                    cloudFields(provider)
                } else {
                    SpeechModelsList(language: $language)
                }
            }
            Section("Speaker Identification") {
                Toggle("Identify speakers", isOn: $diarization)
                Toggle("Wait for new speakers to be named before summarizing", isOn: $identifyFirst)
                Slider(value: $threshold, in: 0.4...0.95, step: 0.05) { Text("Voice match \(threshold, specifier: "%.2f")") }
                Text("Lower merges more voices into known people; raise it if different people get the same name.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Speakers are found on this Mac for every engine (pyannote segmentation, WeSpeaker voices, VBx clustering), from the word times the engine returns. The same voice prints recognize people across meetings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI Cleanup") {
                Toggle("Clean up transcription (filler words, punctuation)", isOn: $cleanup)
                VStack(alignment: .leading) {
                    Text("Cleanup Prompt")
                    TextEditor(text: Binding(get: { cleanupPrompt.isEmpty ? Prompts.defaultCleanup : cleanupPrompt },
                                             set: { cleanupPrompt = $0 == Prompts.defaultCleanup ? "" : $0 }))
                        .font(.system(size: 12)).frame(height: 110)
                    Button("Reset to Default") { cleanupPrompt = "" }.disabled(cleanupPrompt.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: engine) { load() }
        .onChange(of: baseURL) { save(baseURL, "baseURL") }
        .onChange(of: cloudModel) { save(cloudModel, "model") }
        .onChange(of: apiKey) { if let provider { Keychain.set(CloudTranscriber.keychainKey(provider), $1) } }
    }

    @ViewBuilder private func cloudFields(_ provider: CloudTranscriber.Provider) -> some View {
        TextField("Server URL", text: $baseURL, prompt: Text(provider.defaultURL))
        HStack {
            TextField("Model", text: $cloudModel, prompt: Text(provider.models[0]))
            Menu("Select Model") { ForEach(provider.models, id: \.self) { m in Button(m) { cloudModel = m } } }.fixedSize()
        }
        SecureField(provider.keyRequired ? "API key (stored in Keychain)" : "API key (optional, stored in Keychain)", text: $apiKey)
        Picker("Spoken language", selection: $language) {
            ForEach(TranscriptionLanguage.codes, id: \.self) { Text(TranscriptionLanguage.label($0)).tag($0) }
        }
        Toggle("If the cloud is unavailable, transcribe on this Mac", isOn: $fallback)
        HStack {
            Button("Check") { check(provider) }.disabled(checking)
            if checking { ProgressView().controlSize(.small) }
            if let r = checkResult {
                Text(r.text).font(.caption).foregroundStyle(r.ok ? .green : .red).lineLimit(3).textSelection(.enabled)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Cloud: recordings are uploaded to \(provider.title) for transcription, in parts for long meetings. Speaker identification stays on this Mac, and the live preview during a call always runs on this Mac.")
            if provider == .custom {
                Text("Any server with the OpenAI /audio/transcriptions API: faster-whisper-server, LocalAI, whisper.cpp server…")
            }
            if !CloudTranscriber.configured(provider).hasWordTimes {
                Text("This model returns text without word times: audio goes in 30-second parts and speaker changes are approximate. whisper-1 gives exact times.")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func load() {
        checkResult = nil
        guard let provider else { return }
        let d = UserDefaults.standard
        baseURL = d.string(forKey: CloudTranscriber.defaultsKey(provider, "baseURL")) ?? ""
        cloudModel = d.string(forKey: CloudTranscriber.defaultsKey(provider, "model")) ?? ""
        apiKey = Keychain.get(CloudTranscriber.keychainKey(provider))
    }

    private func save(_ value: String, _ field: String) {
        guard let provider else { return }
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespaces), forKey: CloudTranscriber.defaultsKey(provider, field))
        checkResult = nil
    }

    private func check(_ provider: CloudTranscriber.Provider) {
        checking = true
        checkResult = nil
        let engine = CloudTranscriber.configured(provider)
        Task {
            do {
                try await engine.check()
                checkResult = (true, String(localized: "✓ Works — \(engine.name), model \(engine.model)"))
            } catch {
                checkResult = (false, error.localizedDescription)
            }
            checking = false
        }
    }
}
