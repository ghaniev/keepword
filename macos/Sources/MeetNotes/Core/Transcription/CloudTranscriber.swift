import AVFoundation
import FluidAudio
import Foundation

/// Cloud speech-to-text: OpenAI-style `POST {base}/audio/transcriptions` (OpenAI, Groq, any compatible server)
/// or Deepgram's `POST {base}/listen`. Long tracks are cut at quiet moments into parts under the provider's
/// upload limit, sent one by one, and the word times shifted back to the position in the file.
struct CloudTranscriber: TranscriptionEngine {
    enum Provider: String, CaseIterable, Identifiable {
        case openai, groq, deepgram, custom
        var id: Self { self }

        var title: String {
            switch self {
            case .openai: "OpenAI"
            case .groq: "Groq"
            case .deepgram: "Deepgram"
            case .custom: String(localized: "OpenAI-compatible server")
            }
        }

        var defaultURL: String {
            switch self {
            case .openai: "https://api.openai.com/v1"
            case .groq: "https://api.groq.com/openai/v1"
            case .deepgram: "https://api.deepgram.com/v1"
            case .custom: "http://localhost:8000/v1"
            }
        }

        /// Suggestions for the model field; the first is the default.
        var models: [String] {
            switch self {
            case .openai: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
            case .groq: ["whisper-large-v3-turbo", "whisper-large-v3"]
            case .deepgram: ["nova-3", "nova-2"]
            case .custom: ["whisper-1"]
            }
        }

        /// Request size limit (OpenAI and Groq's free tier: 25 MB), with a margin for the multipart wrapping.
        var maxUploadBytes: Int { self == .deepgram ? 100_000_000 : 24_000_000 }
        var keyRequired: Bool { self != .custom }
    }

    let provider: Provider
    let baseURL: String
    let model: String
    let apiKey: String
    /// ISO 639-1 code; empty = let the service detect it.
    let language: String

    var name: String { provider.title }
    var isLocal: Bool { false }

    static func defaultsKey(_ p: Provider, _ field: String) -> String { "transcription.\(p.rawValue).\(field)" }
    static func keychainKey(_ p: Provider) -> String { "transcriptionAPIKey.\(p.rawValue)" }

    static func configured(_ p: Provider) -> CloudTranscriber {
        let d = UserDefaults.standard
        func value(_ field: String, _ fallback: String) -> String {
            d.string(forKey: defaultsKey(p, field)).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        return CloudTranscriber(provider: p, baseURL: value("baseURL", p.defaultURL), model: value("model", p.models[0]),
                                apiKey: Keychain.get(keychainKey(p)), language: d.string(forKey: "transcriptionLanguage") ?? TranscriptionLanguage.defaultCode)
    }

    /// gpt-4o-transcribe models return plain text without times: they get short parts, and words are spread
    /// over the speech in each part, so speaker identification can still place them.
    var hasWordTimes: Bool { provider == .deepgram || !model.lowercased().contains("gpt-4o") }
    private var maxPartSeconds: Double { !hasWordTimes ? 30 : provider == .deepgram ? 1800 : 600 }

    static let sampleRate = SpeechAudio.sampleRate

    // MARK: - Transcription

    func words(_ url: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [WordTiming] {
        if provider.keyRequired && apiKey.isEmpty { throw CloudTranscriptionError.noKey(name) }
        let samples = try SpeechAudio.load(url)
        let parts = SpeechAudio.parts(samples, maxSeconds: maxPartSeconds)
        var out: [WordTiming] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress(i + 1, parts.count)
            // Whisper invents text for silence ("Продолжение следует…"): never send a part with no sound.
            guard SpeechAudio.hasSound(samples[part]) else { continue }
            // The end of the previous part keeps spelling and names consistent across the cut.
            let prompt = String(out.suffix(40).map(\.word).joined(separator: " ").suffix(200))
            out += try await transcribe(samples, part, prompt: prompt)
        }
        return out
    }

    /// One part, with times shifted to the file. A part that is still too large is cut in two.
    private func transcribe(_ samples: [Float], _ part: Range<Int>, prompt: String) async throws -> [WordTiming] {
        func halves() async throws -> [WordTiming] {
            let cut = SpeechAudio.quietestCut(samples, in: part.lowerBound + part.count / 3..<part.upperBound - part.count / 3)
            let first = try await transcribe(samples, part.lowerBound..<cut, prompt: prompt)
            let tail = first.isEmpty ? prompt : String(first.suffix(40).map(\.word).joined(separator: " ").suffix(200))
            return first + (try await transcribe(samples, cut..<part.upperBound, prompt: tail))
        }
        let canSplit = part.count > Int(Self.sampleRate * 20)
        let audio = try Self.encode(samples[part])
        if audio.data.count > provider.maxUploadBytes && canSplit { return try await halves() }
        let duration = Double(part.count) / Self.sampleRate
        do {
            let span = SpeechAudio.speechSpan(samples[part]) ?? 0...duration
            let offset = Double(part.lowerBound) / Self.sampleRate
            return try await send(audio, prompt: prompt, speech: span)
                .map { WordTiming(word: $0.word, startTime: $0.startTime + offset, endTime: $0.endTime + offset) }
        } catch let e as CloudTranscriptionError where e.isTooLarge && canSplit {
            return try await halves()
        }
    }

    /// Sends 1 s of silence: checks the URL, the key and the model without a real recording.
    func check() async throws {
        if provider.keyRequired && apiKey.isEmpty { throw CloudTranscriptionError.noKey(name) }
        let silence = [Float](repeating: 0, count: Int(Self.sampleRate))
        _ = try await send(try Self.encode(silence[...]), prompt: "", speech: 0...1)
    }

    // MARK: - Requests

    private func send(_ audio: EncodedAudio, prompt: String, speech: ClosedRange<Double>) async throws -> [WordTiming] {
        provider == .deepgram ? try await deepgram(audio) : try await openAI(audio, prompt: prompt, speech: speech)
    }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let base = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .init(charactersIn: "/"))
        guard var c = URLComponents(string: base + path), c.scheme?.hasPrefix("http") == true, c.host != nil else {
            throw CloudTranscriptionError.badURL(baseURL)
        }
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw CloudTranscriptionError.badURL(baseURL) }
        var r = URLRequest(url: url, timeoutInterval: 600)
        r.httpMethod = "POST"
        return r
    }

    private func openAI(_ audio: EncodedAudio, prompt: String, speech: ClosedRange<Double>) async throws -> [WordTiming] {
        var r = try endpoint("/audio/transcriptions")
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var form = Multipart()
        form.field("model", model)
        form.field("response_format", hasWordTimes ? "verbose_json" : "json")
        if hasWordTimes {
            form.field("timestamp_granularities[]", "word")
            form.field("timestamp_granularities[]", "segment")
        }
        form.field("temperature", "0")
        if !language.isEmpty { form.field("language", language) }
        if !prompt.isEmpty { form.field("prompt", prompt) }
        form.file("file", name: "audio.\(audio.ext)", type: audio.mime, data: audio.data)
        r.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = form.body

        struct Reply: Decodable {
            struct W: Decodable { let word: String; let start: Double; let end: Double }
            struct S: Decodable { let start: Double; let end: Double; let text: String; let no_speech_prob: Double?; let avg_logprob: Double? }
            let text: String?; let words: [W]?; let segments: [S]?
        }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: try await data(r)) }
        catch let e as CloudTranscriptionError { throw e }
        catch { throw CloudTranscriptionError.badReply(name) }

        // Whisper's own silence test: a segment it thinks is no speech and is unsure about is dropped.
        let segments = reply.segments ?? []
        let spoken = segments.filter { !(($0.no_speech_prob ?? 0) > 0.6 && ($0.avg_logprob ?? 0) < -1) }
        func inSpeech(_ t: Double) -> Bool { segments.isEmpty || spoken.contains { $0.start - 0.5 <= t && t <= $0.end + 0.5 } }
        if let words = reply.words, !words.isEmpty {
            let kept = words.filter { inSpeech(($0.start + $0.end) / 2) }
            let text = segments.isEmpty ? reply.text ?? "" : spoken.map(\.text).joined(separator: " ")
            return Self.punctuated(kept.map { WordTiming(word: $0.word, startTime: $0.start, endTime: $0.end) }, from: text)
        }
        if !segments.isEmpty {
            return spoken.flatMap { Self.spread($0.text, over: $0.start...max($0.start, $0.end)) }
        }
        return Self.spread(reply.text ?? "", over: speech)
    }

    private func deepgram(_ audio: EncodedAudio) async throws -> [WordTiming] {
        var query = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "smart_format", value: "true"),
                     URLQueryItem(name: "punctuate", value: "true")]
        query.append(language.isEmpty ? URLQueryItem(name: "detect_language", value: "true") : URLQueryItem(name: "language", value: language))
        var r = try endpoint("/listen", query: query)
        r.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue(audio.mime, forHTTPHeaderField: "Content-Type")
        r.httpBody = audio.data

        struct Reply: Decodable {
            struct Results: Decodable { let channels: [Channel] }
            struct Channel: Decodable { let alternatives: [Alternative] }
            struct Alternative: Decodable { let words: [W]? }
            struct W: Decodable { let word: String; let punctuated_word: String?; let start: Double; let end: Double }
            let results: Results
        }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: try await data(r))
            return (reply.results.channels.first?.alternatives.first?.words ?? [])
                .map { WordTiming(word: $0.punctuated_word ?? $0.word, startTime: $0.start, endTime: $0.end) }
        } catch let e as CloudTranscriptionError { throw e }
        catch { throw CloudTranscriptionError.badReply(name) }
    }

    /// Sends with up to two retries on rate limits, server errors and dropped connections.
    private func data(_ r: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let retry = attempt < 3
            do {
                let (data, response) = try await URLSession.shared.data(for: r)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if code == 200 { return data }
                if retry && (code == 429 || code >= 500) {
                    let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "").map { min($0, 30) } ?? Double(attempt * 3)
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                throw CloudTranscriptionError.http(name, code, Self.errorText(data))
            } catch let e as URLError {
                if retry && [.timedOut, .networkConnectionLost].contains(e.code) {
                    try await Task.sleep(for: .seconds(Double(attempt * 3)))
                    continue
                }
                if e.code == .cancelled { throw CancellationError() }
                throw CloudTranscriptionError.network(r.url?.host() ?? baseURL, e)
            }
        }
    }

    /// The provider's own error message (OpenAI: error.message, Deepgram: err_msg), else the start of the body.
    static func errorText(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = (obj["err_msg"] ?? obj["message"] ?? obj["error"]) as? String { return m }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    // MARK: - Words

    /// Whisper's word list has no punctuation or capitals; take each word's spelling from the full text.
    static func punctuated(_ words: [WordTiming], from text: String) -> [WordTiming] {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var next = 0
        return words.map { w in
            let k = key(w.word)
            guard !k.isEmpty, let j = (next..<min(next + 4, tokens.count)).first(where: { key(tokens[$0]) == k }) else { return w }
            next = j + 1
            return WordTiming(word: tokens[j], startTime: w.startTime, endTime: w.endTime)
        }
    }

    /// Plain text over a time span, each word getting time in proportion to its length.
    static func spread(_ text: String, over span: ClosedRange<Double>) -> [WordTiming] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = tokens.reduce(0) { $0 + $1.count + 1 }
        guard total > 0 else { return [] }
        let perChar = (span.upperBound - span.lowerBound) / Double(total)
        var t = span.lowerBound
        return tokens.map { token in
            let d = Double(token.count + 1) * perChar
            defer { t += d }
            return WordTiming(word: token, startTime: t, endTime: t + d * 0.9)
        }
    }

    // MARK: - Upload

    struct EncodedAudio { let data: Data; let ext: String; let mime: String }

    /// AAC in .m4a (~4 KB/s, so a 10-minute part is ~2.5 MB); 16-bit WAV if the encoder isn't available.
    static func encode(_ samples: ArraySlice<Float>) throws -> EncodedAudio {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) {
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { p in
                if let base = p.baseAddress { buffer.floatChannelData![0].update(from: base, count: p.count) }
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "meetnotes-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                do {
                    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                                          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000],
                                               commonFormat: .pcmFormatFloat32, interleaved: false)
                    try file.write(from: buffer)
                }  // the file is finished when it goes out of scope
                let data = try Data(contentsOf: url)
                if !data.isEmpty { return EncodedAudio(data: data, ext: "m4a", mime: "audio/mp4") }
            } catch {}
        }
        return EncodedAudio(data: wav(samples), ext: "wav", mime: "audio/wav")
    }

    static func wav(_ samples: ArraySlice<Float>) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(bytes)
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

private struct Multipart {
    let boundary = "MeetNotes-\(UUID().uuidString)"
    var body = Data()
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, name filename: String, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    }
}

enum CloudTranscriptionError: LocalizedError {
    case noKey(String), badURL(String), network(String, URLError), http(String, Int, String), badReply(String)
    var isTooLarge: Bool { if case .http(_, 413, _) = self { true } else { false } }

    var errorDescription: String? {
        switch self {
        case .noKey(let p): String(localized: "Enter an API key for \(p) in Settings → Transcription.")
        case .badURL(let u): String(localized: "Invalid server URL: \(u)")
        case .network(let host, let e):
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                String(localized: "No internet connection — can't reach \(host).")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                String(localized: "Can't connect to \(host). Check the server URL.")
            case .timedOut: String(localized: "\(host) didn't respond in time.")
            default: String(localized: "Can't reach \(host): \(e.localizedDescription)")
            }
        case .http(let p, let code, let text):
            switch code {
            case 401, 403: String(localized: "\(p) rejected the API key. Check it in Settings → Transcription.")
            case 404: String(localized: "\(p): not found (404). Check the server URL and the model name.")
            case 413: String(localized: "\(p): the audio part is too large.")
            case 429: String(localized: "\(p): rate limit or quota exceeded. Try again later or check your plan.")
            default: String(localized: "\(p) error \(code): \(text)")
            }
        case .badReply(let p): String(localized: "Unexpected reply from \(p).")
        }
    }
}

/// Spoken language sent to cloud engines. Parakeet detects it by itself.
enum TranscriptionLanguage {
    static let codes = ["", "ru", "en", "uk", "kk", "uz", "be", "de", "fr", "es", "it", "pt", "pl", "tr", "zh", "ja"]
    /// Russian when the app runs in Russian, otherwise auto-detect.
    static var defaultCode: String { Bundle.main.preferredLocalizations.first == "ru" ? "ru" : "" }

    static func label(_ code: String) -> String {
        code.isEmpty ? String(localized: "Auto-detect") : (Locale.current.localizedString(forLanguageCode: code) ?? code).capitalized
    }
}
