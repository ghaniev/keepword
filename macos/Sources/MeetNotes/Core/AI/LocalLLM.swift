import Foundation
import llama

/// Built-in local LLM: Qwen GGUF models run in-process with llama.cpp on the GPU (Metal).
/// No Ollama, no key, works offline.
struct LocalModel: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let bytes: Int64
    let minRAMGB: Int  // below this the model doesn't fit next to the app, the speech models and macOS
    let contextTokens: Int32

    var fileURL: URL { LocalModels.dir.appending(path: url.lastPathComponent) }
    var isDownloaded: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0) == bytes
    }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum LocalModels {
    // Qwen line-up, Q4_K_M quantization; sizes checked against HuggingFace.
    static let catalog = [
        LocalModel(id: "qwen3.5-4b", name: "Qwen3.5 4B",
                   url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
                   bytes: 2_740_937_888, minRAMGB: 8, contextTokens: 16_384),
        LocalModel(id: "qwen3.5-9b", name: "Qwen3.5 9B",
                   url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf")!,
                   bytes: 5_680_522_464, minRAMGB: 24, contextTokens: 32_768),
        LocalModel(id: "qwen3.6-27b", name: "Qwen3.6 27B",
                   url: URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.6-27B-GGUF/resolve/c01339d801f906aa5411809956852b23fb394ae3/Qwen_Qwen3.6-27B-Q4_K_M.gguf")!,
                   bytes: 17_533_552_192, minRAMGB: 48, contextTokens: 32_768),
    ]

    static var dir: URL { Store.dataDir.appending(path: "Models/LLM") }
    static var ramGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    /// The largest model that fits this Mac ("Best for your Mac").
    static var recommended: LocalModel { recommended(forRAM: ramGB) }
    static func recommended(forRAM gb: Int) -> LocalModel { catalog.last { gb >= $0.minRAMGB } ?? catalog[0] }
    static func find(_ id: String) -> LocalModel? { catalog.first { $0.id == id } }
    static let providerURL = "local:llama"
}

/// Owns the loaded model and context; one generation at a time.
actor LlamaEngine {
    static let shared = LlamaEngine()
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedID: String?
    private var unloadTask: Task<Void, Never>?
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)  // llama.cpp is chatty on stderr
        llama_backend_init()
    }()

    func generate(_ m: LocalModel, messages: [[String: String]], maxTokens: Int32 = 3_000) throws -> String {
        unloadTask?.cancel()
        try load(m)
        defer { scheduleUnload() }
        guard let model, let context else { throw LLMError(message: "Local model not loaded") }
        let vocab = llama_model_get_vocab(model)

        var prompt = try Self.applyTemplate(model, messages)
        // Qwen3.x thinks out loud by default; an empty think block switches to direct answers (faster, cleaner JSON).
        if let t = llama_model_chat_template(model, nil), String(cString: t).contains("<think>") {
            prompt += "<think>\n\n</think>\n\n"
        }
        var tokens = Self.tokenize(vocab, prompt)
        let ctx = Int32(llama_n_ctx(context))
        guard Int32(tokens.count) + 64 < ctx else {
            throw LLMError(message: "This meeting is too long for \(m.name)'s \(ctx / 1024)K context. Try a larger model or a cloud provider.")
        }

        llama_memory_clear(llama_get_memory(context), true)
        let batch = 2048
        for start in stride(from: 0, to: tokens.count, by: batch) {
            let n = Int32(min(batch, tokens.count - start))
            let rc = tokens.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress! + start, n)) }
            guard rc == 0 else { throw LLMError(message: "Local model failed to read the prompt (\(rc))") }
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.8, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.5))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        var out = Data()
        var piece = [CChar](repeating: 0, count: 256)
        let limit = min(maxTokens, ctx - Int32(tokens.count) - 1)
        for _ in 0..<limit {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { piece.withUnsafeBytes { out.append(contentsOf: $0.prefix(Int(n))) } }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { break }
        }
        tokens.removeAll()
        return String(decoding: out, as: UTF8.self)
    }

    private func load(_ m: LocalModel) throws {
        if loadedID == m.id, context != nil { return }
        unload()
        guard m.isDownloaded else { throw LLMError(message: "\(m.name) is not downloaded yet. Open Settings → AI Provider to download it.") }
        // Memory guard: check free memory before loading a model.
        guard Double(m.bytes) < Double(ProcessInfo.processInfo.physicalMemory) * 0.6 else {
            throw LLMError(message: "Not enough memory to load \(m.name) on this Mac. Choose a smaller model.")
        }
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999  // everything on the GPU
        guard let model = llama_model_load_from_file(m.fileURL.path, mp) else {
            throw LLMError(message: "Could not load \(m.name). The file may be damaged — delete and download it again.")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(m.contextTokens)
        cp.n_batch = 2048
        cp.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        cp.n_threads_batch = cp.n_threads
        guard let context = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw LLMError(message: "Could not create a context for \(m.name) (out of memory?).")
        }
        self.model = model
        self.context = context
        loadedID = m.id
    }

    /// Frees the ~3–20 GB the model holds after 5 idle minutes.
    private func scheduleUnload() {
        unloadTask = Task {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self.unload()
        }
    }

    /// Must run before the process exits: ggml's Metal device aborts at exit if a model is still loaded.
    nonisolated static func shutdownBlocking() {
        let done = DispatchSemaphore(value: 0)
        Task.detached { await LlamaEngine.shared.unload(); done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loadedID = nil
    }

    static func applyTemplate(_ model: OpaquePointer, _ messages: [[String: String]]) throws -> String {
        let tmpl = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0["role"] ?? "user") }
        let contents = messages.map { strdup($0["content"] ?? "") }
        defer { (roles + contents).forEach { free($0) } }
        let chat = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        var size = Int32(messages.reduce(1024) { $0 + 2 * ($1["content"]?.utf8.count ?? 0) })
        for _ in 0..<2 {
            var buf = [CChar](repeating: 0, count: Int(size))
            let n = llama_chat_apply_template(tmpl, chat, chat.count, true, &buf, size)
            guard n >= 0 else { throw LLMError(message: "This model's chat template is not supported") }
            if n <= size { return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            size = n + 1
        }
        throw LLMError(message: "Chat template failed")
    }

    static func tokenize(_ vocab: OpaquePointer?, _ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let len = Int32(utf8.count - 1)
        let needed = -llama_tokenize(vocab, utf8, len, nil, 0, true, true)
        var tokens = [llama_token](repeating: 0, count: Int(max(needed, 1)))
        let n = llama_tokenize(vocab, utf8, len, &tokens, Int32(tokens.count), true, true)
        return Array(tokens.prefix(Int(max(n, 0))))
    }
}

/// Downloads models with progress and cancel ("Download and use Local AI").
@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: [String: Double] = [:]  // model id → 0…1 while downloading
    @Published var error: String?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var finished: [String: () -> Void] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func download(_ m: LocalModel, then done: @escaping () -> Void = {}) {
        guard tasks[m.id] == nil else { return }
        error = nil
        let free = (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free > m.bytes + 2_000_000_000 else {
            error = "Not enough disk space for \(m.name) (\(m.sizeLabel))."
            return
        }
        let task = session.downloadTask(with: m.url)
        task.taskDescription = m.id
        tasks[m.id] = task
        finished[m.id] = done
        progress[m.id] = 0
        task.resume()
    }

    func cancel(_ m: LocalModel) {
        tasks[m.id]?.cancel()
        tasks[m.id] = nil
        progress[m.id] = nil
    }

    func delete(_ m: LocalModel) {
        Task { await LlamaEngine.shared.unload() }
        try? FileManager.default.removeItem(at: m.fileURL)
        objectWillChange.send()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription ?? ""
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (LocalModels.find(id)?.bytes ?? 1)
        MainActor.assumeIsolated { progress[id] = Double(totalBytesWritten) / Double(expected) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file disappears when this returns, so move it synchronously.
        let id = downloadTask.taskDescription ?? ""
        guard let m = LocalModels.find(id) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var failure: String?
        do {
            guard status == 200 else { throw LLMError(message: "HTTP \(status)") }
            try FileManager.default.createDirectory(at: LocalModels.dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: m.fileURL)
            try FileManager.default.moveItem(at: location, to: m.fileURL)
            if !m.isDownloaded { failure = "Download of \(m.name) is incomplete. Try again." }
        } catch { failure = "Download of \(m.name) failed: \(error.localizedDescription)" }
        MainActor.assumeIsolated {
            tasks[id] = nil
            progress[id] = nil
            if let failure { self.error = failure } else { finished[id]?() }
            finished[id] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let id = task.taskDescription ?? ""
        MainActor.assumeIsolated {
            tasks[id] = nil
            progress[id] = nil
            self.error = "Download failed: \(error.localizedDescription)"
        }
    }
}
