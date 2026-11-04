import FluidAudio
import Foundation

/// FluidAudio's word type under a name that doesn't clash with WhisperKit's `WordTiming`.
typealias TimedWord = WordTiming

/// Speech-to-text for a finished recording track. Speaker identification is separate (always on this Mac,
/// from the same word times), so an engine only turns one audio file into timed words.
protocol TranscriptionEngine: Sendable {
    var name: String { get }
    /// Runs on this Mac (nothing to fall back from).
    var isLocal: Bool { get }
    /// Words with times in seconds from the start of the file. `progress(part, parts)` reports long files cut into parts.
    func words(_ url: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [WordTiming]
}

enum TranscriptionEngines {
    /// `transcriptionEngine`: "local" (the model in `localSpeechModel`) or a `CloudTranscriber.Provider` raw value.
    static var current: any TranscriptionEngine {
        let id = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "local"
        guard let provider = CloudTranscriber.Provider(rawValue: id) else { return SpeechModels.selected.engine }
        return CloudTranscriber.configured(provider)
    }
}

/// A downloadable on-device speech model: Parakeet (FluidAudio) or Whisper (WhisperKit), both on Core ML.
struct SpeechModel: Identifiable, Sendable {
    enum Kind: Sendable { case parakeet(AsrModelVersion), whisper(variant: String) }
    let id: String
    let name: String
    let kind: Kind
    let bytes: Int64  // download size, checked against HuggingFace
    let note: LocalizedStringResource

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var isWhisper: Bool { if case .whisper = kind { true } else { false } }

    var isDownloaded: Bool {
        switch kind {
        case .parakeet(let v): AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: v), version: v)
        case .whisper: FileManager.default.fileExists(atPath: WhisperTranscriber.readyMarker(self).path)
        }
    }

    /// Model files on disk (Parakeet in FluidAudio's cache, Whisper in MeetNotes/Models/Whisper).
    var folder: URL {
        switch kind {
        case .parakeet(let v): AsrModels.defaultCacheDirectory(for: v)
        case .whisper: WhisperTranscriber.folder(self)
        }
    }

    /// `preparing` is called when the files are in and the model is being compiled for this Mac.
    func download(progress: @escaping @Sendable (Double) -> Void, preparing: @escaping @Sendable () -> Void = {}) async throws {
        switch kind {
        case .parakeet(let version): try await AsrModels.download(version: version) { progress($0.fractionCompleted) }
        case .whisper: try await WhisperTranscriber.download(self, progress: progress, preparing: preparing)
        }
    }

    var engine: any TranscriptionEngine {
        switch kind {
        case .parakeet: ParakeetEngine(model: self)
        case .whisper: WhisperEngine(model: self)
        }
    }
}

enum SpeechModels {
    static let catalog: [SpeechModel] = [
        SpeechModel(id: "parakeet-v3", name: "Parakeet TDT v3", kind: .parakeet(.v3), bytes: 480_000_000,
                    note: "25 European languages including Russian. Fast on the Neural Engine; used for the live preview."),
        SpeechModel(id: "parakeet-ultra", name: "Parakeet Ultra", kind: .parakeet(.ultra), bytes: 650_000_000,
                    note: "Retrained v3: more accurate in all 25 languages, a little slower."),
        SpeechModel(id: "parakeet-redux", name: "Parakeet Redux", kind: .parakeet(.redux), bytes: 220_000_000,
                    note: "The smallest: 2-bit v3, about as accurate, 25 languages."),
        SpeechModel(id: "parakeet-v2", name: "Parakeet TDT v2", kind: .parakeet(.v2), bytes: 480_000_000,
                    note: "English only; the most accurate for English meetings."),
        SpeechModel(id: "whisper-tiny", name: "Whisper Tiny", kind: .whisper(variant: "openai_whisper-tiny"), bytes: 77_000_000,
                    note: "99 languages. Very fast, rough text — for trying Whisper out."),
        SpeechModel(id: "whisper-base", name: "Whisper Base", kind: .whisper(variant: "openai_whisper-base"), bytes: 147_000_000,
                    note: "99 languages. Fast drafts."),
        SpeechModel(id: "whisper-small", name: "Whisper Small", kind: .whisper(variant: "openai_whisper-small"), bytes: 486_000_000,
                    note: "99 languages. Decent Russian on any Mac."),
        SpeechModel(id: "whisper-medium", name: "Whisper Medium", kind: .whisper(variant: "openai_whisper-medium"), bytes: 1_530_000_000,
                    note: "99 languages. More accurate, several times slower than Small."),
        SpeechModel(id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", kind: .whisper(variant: "openai_whisper-large-v3-v20240930_626MB"),
                    bytes: 627_000_000, note: "99 languages. Close to Large v3 and much faster — the best Whisper for most Macs."),
        SpeechModel(id: "whisper-large-v3", name: "Whisper Large v3", kind: .whisper(variant: "openai_whisper-large-v3_947MB"), bytes: 948_000_000,
                    note: "99 languages. The most accurate Whisper, the slowest. Best with 16 GB of memory or more."),
    ]

    static let defaultID = "parakeet-v3"
    static func find(_ id: String) -> SpeechModel? { catalog.first { $0.id == id } }
    static var parakeetV3: SpeechModel { find(defaultID)! }

    /// The chosen on-device model; Parakeet v3 (downloaded on first use) when the chosen one isn't on disk.
    static var selected: SpeechModel {
        guard let m = find(UserDefaults.standard.string(forKey: "localSpeechModel") ?? defaultID), m.isDownloaded else { return parakeetV3 }
        return m
    }
}

struct ParakeetEngine: TranscriptionEngine {
    let model: SpeechModel
    var name: String { model.name }
    var isLocal: Bool { true }

    func words(_ url: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [WordTiming] {
        try await LocalTranscriber.shared.words(url, model: model)
    }
}

/// Loaded Parakeet models; one batch manager at a time (meetings are processed one by one).
actor LocalTranscriber {
    static let shared = LocalTranscriber()
    private var models: [String: AsrModels] = [:]
    private var asr: (id: String, manager: AsrManager)?

    /// Downloads on first use (Parakeet v3 has always worked that way). At most two stay loaded: the live
    /// preview's and the one chosen for processing.
    func loadedModels(_ m: SpeechModel = SpeechModels.parakeetV3) async throws -> AsrModels {
        if let loaded = models[m.id] { return loaded }
        guard case .parakeet(let version) = m.kind else { throw LLMError(message: "\(m.name) is not a Parakeet model") }
        let loaded = try await AsrModels.downloadAndLoad(version: version)
        if models.count >= 2, let drop = models.keys.first(where: { $0 != SpeechModels.defaultID }) { models[drop] = nil }
        models[m.id] = loaded
        return loaded
    }

    /// The live preview runs the chosen Parakeet, or v3 when Whisper or a cloud engine is chosen.
    func liveModels() async throws -> AsrModels {
        let chosen = SpeechModels.selected
        if case .parakeet = chosen.kind { return try await loadedModels(chosen) }
        return try await loadedModels()
    }

    func words(_ url: URL, model m: SpeechModel) async throws -> [WordTiming] {
        if asr?.id != m.id {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(try await loadedModels(m))
            asr = (m.id, manager)
        }
        guard let manager = asr?.manager else { return [] }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state)
        return buildWordTimings(from: result.tokenTimings ?? [])
    }

    func unload(_ m: SpeechModel) {
        models[m.id] = nil
        if asr?.id == m.id { asr = nil }
    }
}
