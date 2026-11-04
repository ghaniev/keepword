import Foundation
import WhisperKit

struct WhisperEngine: TranscriptionEngine {
    let model: SpeechModel
    var name: String { model.name }
    var isLocal: Bool { true }

    func words(_ url: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [TimedWord] {
        try await WhisperTranscriber.shared.words(url, model: model, progress: progress)
    }
}

/// Whisper on Core ML through WhisperKit. Models come from argmaxinc/whisperkit-coreml and live in
/// Application Support/MeetNotes/Models/Whisper; one is loaded at a time and unloaded after each meeting.
actor WhisperTranscriber {
    static let shared = WhisperTranscriber()
    private var loaded: (id: String, kit: WhisperKit)?

    static var root: URL { URL.applicationSupportDirectory.appending(path: "MeetNotes/Models/Whisper") }

    static func folder(_ m: SpeechModel) -> URL {
        guard case .whisper(let variant) = m.kind else { return root }
        return root.appending(path: "models/argmaxinc/whisperkit-coreml/\(variant)")
    }

    /// Written once the model has been compiled for this Mac and its tokenizer fetched: from then on it works offline.
    static func readyMarker(_ m: SpeechModel) -> URL { folder(m).appending(path: ".meetnotes-ready") }

    static func download(_ m: SpeechModel, progress: @escaping @Sendable (Double) -> Void,
                         preparing: @escaping @Sendable () -> Void) async throws {
        guard case .whisper(let variant) = m.kind else { return }
        let folder = try await WhisperKit.download(variant: variant, downloadBase: root) { progress($0.fractionCompleted) }
        try Task.checkCancellation()
        preparing()
        // The first load specializes the models for this Mac's Neural Engine (up to a few minutes for large ones).
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: root, verbose: false,
                                                        logLevel: .error, prewarm: true, load: true, download: false))
        await kit.unloadModels()
        try Task.checkCancellation()
        try Data().write(to: folder.appending(path: ".meetnotes-ready"))
    }

    func words(_ url: URL, model m: SpeechModel, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [TimedWord] {
        let kit = try await kit(for: m)
        let samples = try SpeechAudio.load(url)
        let language = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? TranscriptionLanguage.defaultCode
        let options = DecodingOptions(language: language.isEmpty ? nil : language, detectLanguage: language.isEmpty,
                                      skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        // 5-minute parts give progress and keep memory flat; inside a part WhisperKit cuts by voice activity.
        let parts = SpeechAudio.parts(samples, maxSeconds: 300)
        var out: [TimedWord] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress(i + 1, parts.count)
            // Whisper invents text for silence ("Продолжение следует…").
            guard SpeechAudio.hasSound(samples[part]) else { continue }
            let offset = Double(part.lowerBound) / SpeechAudio.sampleRate
            let results = try await kit.transcribe(audioArray: Array(samples[part]), decodeOptions: options)
            for segment in results.flatMap(\.segments) {
                for w in segment.words ?? [] {
                    let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !text.hasPrefix("<|") else { continue }
                    out.append(TimedWord(word: text, startTime: Double(w.start) + offset, endTime: Double(w.end) + offset))
                }
            }
        }
        return out.sorted { $0.startTime < $1.startTime }
    }

    private func kit(for m: SpeechModel) async throws -> WhisperKit {
        if let loaded, loaded.id == m.id { return loaded.kit }
        await unload()
        guard m.isDownloaded else {
            throw LLMError(message: String(localized: "\(m.name) isn't downloaded. Download it in Settings → Transcription."))
        }
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: Self.folder(m).path, tokenizerFolder: Self.root, verbose: false,
                                                        logLevel: .error, load: true, download: false))
        loaded = (m.id, kit)
        return kit
    }

    func unload() async {
        await loaded?.kit.unloadModels()
        loaded = nil
    }
}
