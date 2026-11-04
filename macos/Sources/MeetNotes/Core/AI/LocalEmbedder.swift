import CoreML
import Embeddings
import Foundation

/// On-device sentence embeddings: paraphrase-multilingual-MiniLM-L12-v2 (50+ languages, 384-d,
/// mean pooling) run through Core ML via swift-embeddings. No server, no API key; downloaded once (~470 MB).
actor LocalEmbedder {
    static let shared = LocalEmbedder()
    static let repo = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    static var modelsDir: URL { Store.dataDir.appending(path: "Models") }

    private var bundle: Bert.ModelBundle?
    private var loading: Task<Bert.ModelBundle, Error>?

    private func model() async throws -> Bert.ModelBundle {
        if let bundle { return bundle }
        if loading == nil {
            // The repo names its tokenizer "PreTrainedTokenizerFast"; it is XLM-R's Unigram tokenizer (tokenizer.json),
            // so say so explicitly, otherwise swift-transformers falls back to BPE.
            let tokenizerConfig: [String: Any] = [
                "tokenizer_class": "XLMRobertaTokenizer", "bos_token": "<s>", "eos_token": "</s>", "unk_token": "<unk>",
                "pad_token": "<pad>", "cls_token": "<s>", "sep_token": "</s>", "mask_token": "<mask>", "model_max_length": 512,
            ]
            loading = Task {
                try await Bert.loadModelBundle(from: Self.repo, downloadBase: Self.modelsDir,
                                               loadConfig: LoadConfig(tokenizerConfig: TokenizerConfig(config: .data(tokenizerConfig))))
            }
        }
        do {
            let b = try await loading!.value
            bundle = b
            return b
        } catch {
            loading = nil  // allow a retry (e.g. offline on first use)
            throw error
        }
    }

    func tokenIDs(_ text: String) async throws -> [Int32] { try await model().tokenizer.tokenizeText(text) }

    func poolingDescription() async throws -> String {
        let o = try await model().defaultEncodeOptions
        return "maxLength=\(o.maxLength) postProcess=\(String(describing: o.postProcess))"
    }

    /// One vector per text. The model reads at most 128 tokens per text; longer input is truncated.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        let m = try await model()
        var out: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: 16) {
            let batch = Array(texts[start..<min(start + 16, texts.count)])
            var options = m.defaultEncodeOptions  // mean pooling, 128 tokens (from the sentence-transformers config)
            options.padTokenId = 1  // <pad>; the BERT config says 0, which is <s> in this vocabulary
            let array = await (try m.batchEncode(batch, options: options)).cast(to: Float.self).shapedArray(of: Float.self)
            let dim = array.shape.last ?? 0
            let scalars = array.scalars
            for i in batch.indices { out.append(Array(scalars[i * dim..<(i + 1) * dim])) }
        }
        return out
    }
}

/// Where vectors come from: the built-in model (default), an OpenAI-compatible /embeddings server, or nowhere.
enum Embedder {
    static var source: String { UserDefaults.standard.string(forKey: "embeddingSource") ?? "local" }

    /// Identifies the vector space; vectors from different models can't be compared, so a change means reindexing.
    static var modelID: String? {
        let id: String? = switch source {
        case "local": "local:" + LocalEmbedder.repo
        case "server": LLM.embedder.map { "server:\($0.baseURL)|\($0.model)" }
        default: nil
        }
        return id.map { "\($0)|\(Pipeline.chunkVersion)" }  // chunking changes also need a reindex
    }

    static func embed(_ texts: [String]) async throws -> [[Float]]? {
        switch source {
        case "local": return try await LocalEmbedder.shared.embed(texts)
        case "server":
            guard let e = LLM.embedder else { return nil }
            return try await e.embed(texts)
        default: return nil
        }
    }
}
