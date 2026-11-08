import AVFoundation
import FluidAudio
import Foundation
import GRDB

/// Post-recording pipeline:
/// transcribe → diarize → match voices → echo dedup → AI cleanup → summarize (template) → index → export.
actor Pipeline {
    static let shared = Pipeline()
    static let voiceModel = "wespeaker_v2"
    private var diarizerModels: OfflineDiarizerModels?  // loaded once; each meeting gets its own diarizer config

    private var defaults: UserDefaults { .standard }
    private func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.flag(key, fallback) }

    /// Processes a recording; returns a notice for the user when the cloud engine failed and this Mac took over.
    @discardableResult
    func process(_ id: String, store: Store) async -> String? {
        var notice: String?
        do {
            try store.setStatus(id, "processing:transcribing")
            let dir = Store.dataDir.appending(path: "recordings/\(id)")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let mic = files.first { $0.lastPathComponent == "mic.caf" }
            let others = files.filter { $0.lastPathComponent == "system.caf" || $0.lastPathComponent.hasPrefix("import.") }

            var engine = TranscriptionEngines.current
            func words(_ url: URL) async throws -> [WordTiming] {
                do {
                    return try await engine.words(url) { part, parts in
                        try? store.setStatus(id, parts > 1 ? "processing:transcribing \(part)/\(parts)" : "processing:transcribing")
                    }
                } catch where !engine.isLocal && !(error is CancellationError) && flag("transcriptionFallbackLocal", true) {
                    // Offline or a bad key: the rest of this recording stays on this Mac too, so tracks stay consistent.
                    notice = String(localized: "\(engine.name) transcription failed, transcribed on this Mac instead: \(error.localizedDescription)")
                    engine = SpeechModels.selected.engine
                    try? store.setStatus(id, "processing:transcribing-local")
                    return try await engine.words(url) { _, _ in }
                }
            }

            var turns: [Utterance] = []
            if let mic { turns = Self.utterances(try await words(mic).map { Word(w: $0, speaker: Speaker.meID) }) }
            for url in others {
                var ws = try await words(url).map { Word(w: $0, speaker: "") }
                guard !ws.isEmpty else { continue }
                if flag("diarization", true) {
                    try store.setStatus(id, "processing:diarizing")
                    let labels = try await speakerLabels(url, store: store, meeting: store.meeting(id))
                    for i in ws.indices {
                        guard let l = Self.label(ws[i].start, ws[i].end, in: labels) else { continue }
                        (ws[i].speaker, ws[i].overlap) = (l.speaker, l.overlap)
                    }
                }
                let theirs = Self.utterances(ws)
                turns = Self.dropEchoes(mic: turns, system: theirs) + theirs
            }
            await WhisperTranscriber.shared.unload()  // ~1 GB the summary's local LLM may need

            let duration = files.compactMap { try? AVAudioFile(forReading: $0) }
                .map { Double($0.length) / $0.fileFormat.sampleRate }.max() ?? 0
            let sorted = turns.sorted { $0.start < $1.start }
            try await store.db.write { db in
                try db.execute(sql: "UPDATE meetings SET duration = ? WHERE id = ?", arguments: [duration, id])
                try db.execute(sql: "DELETE FROM segments WHERE meeting_id = ?", arguments: [id])
                for u in sorted {
                    var s = Segment(meetingId: id, speakerId: u.speaker.isEmpty ? nil : u.speaker,
                                    source: u.speaker == Speaker.meID ? "mic" : "system", start: u.start, end: u.end, text: u.text)
                    s.overlap = u.overlap
                    try s.insert(db)
                }
            }
            guard !sorted.isEmpty else { try store.setStatus(id, "error:No speech detected"); return notice }

            if flag("aiCleanup", true) {
                try store.setStatus(id, "processing:cleanup")
                await cleanup(id, store: store)
            }
            if flag("identifySpeakersFirst", false), !(try store.unnamedSpeakers(in: id)).isEmpty {
                // "Pause summarization for new speakers": the summary waits for real names.
                try store.setStatus(id, "awaiting:speakers")
            } else if flag("autoSummarize", true) {
                try await summarize(id, store: store)
            } else {
                try store.setStatus(id, "done")
            }
            await index(id, store: store)
            if flag("deleteAudioAfterProcessing", false) { for f in files { try? FileManager.default.removeItem(at: f) } }
        } catch {
            try? store.setStatus(id, "error:\(error.localizedDescription)")
        }
        return notice
    }

    // MARK: - Summary

    struct Notes: Decodable {
        struct I: Decodable { let text: String; let time: String? }
        struct A: Decodable { let text: String; let assignee: String?; let due: String? }
        let title: String?; let overview: String?; let insights: [I]?; let action_items: [A]?; let tags: [String]?
    }

    /// Builds the summary with the meeting's template; nothing is saved. Long meetings go through map-reduce
    /// (as in Meetily): overlapping parts are condensed to time-stamped notes, then the notes are summarized.
    static func draftNotes(_ m: Meeting, store: Store, progress: (String) -> Void = { _ in }) async throws -> Notes {
        let all = try store.speakers()
        let lines = try store.segments(of: m.id).filter { !$0.irrelevant }
            .map { "[\(timestamp($0.start))] \(store.root($0.speakerId, in: all)?.name ?? "Speaker"): \($0.text)" }
        guard let template = try store.template(for: m) else { throw LLMError(message: "No summary template") }
        let llm = LLM.current
        var input = lines.joined(separator: "\n")
        if input.count > llm.maxInputChars {
            input = "Condensed notes from consecutive parts of a long meeting; [mm:ss] times are from the start of the recording.\n\n"
                + (try await condense(lines, llm: llm, progress: progress)).joined(separator: "\n")
        }
        return try await llm.json(Notes.self, system: Prompts.summary(template: template, recordedAt: m.createdAt,
                                                                    folderContext: try store.folderContext(for: m)),
                                  user: input)
    }

    /// Map step, repeated until the notes fit one request.
    static func condense(_ lines: [String], llm: LLM, progress: (String) -> Void, level: Int = 0) async throws -> [String] {
        let parts = chunkLines(lines, maxChars: Int(Double(llm.maxInputChars) * 0.75), overlapChars: 350)
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            progress("\(i + 1)/\(parts.count)")
            let span = "\(part.first?.prefix(while: { $0 != "]" }).dropFirst() ?? "")–\(part.last?.prefix(while: { $0 != "]" }).dropFirst() ?? "")"
            var result: String?
            for attempt in 1...2 where result == nil {  // one retry per part, like Meetily
                result = try? await llm.chat(system: Prompts.partNotes, user: "Part \(i + 1) of \(parts.count) (\(span)):\n" + part.joined(separator: "\n"))
                if result == nil && attempt == 2 { notes.append("## Part \(i + 1) (\(span)): could not be summarized") }
            }
            if let result { notes.append("## Part \(i + 1) (\(span))\n\(result)") }
        }
        guard notes.contains(where: { !$0.hasSuffix("could not be summarized") }) else {
            throw LLMError(message: "Could not summarize any part of this long meeting.")
        }
        let limit = llm.maxInputChars
        let inputSize = lines.joined(separator: "\n").count
        let joined = notes.joined(separator: "\n").split(separator: "\n").map(String.init)
        let size = joined.joined(separator: "\n").count
        if size <= limit { return joined }
        // Recurse only while each level really shrinks the text; otherwise trim every part evenly so the end
        // of the meeting is never the part that gets dropped.
        if level < 3, Double(size) < Double(inputSize) * 0.8 {
            return try await condense(joined, llm: llm, progress: progress, level: level + 1)
        }
        return evenlyTrimmed(notes, limit: limit)
    }

    /// Cuts each part's notes to an equal share of `limit`, keeping whole lines (bullets) from the top of each part.
    static func evenlyTrimmed(_ parts: [String], limit: Int) -> [String] {
        let budget = max(1, limit / max(1, parts.count))
        return parts.flatMap { part -> [String] in
            var kept: [String] = []
            var used = 0
            for line in part.split(separator: "\n").map(String.init) where used + line.count + 1 <= budget {
                kept.append(line)
                used += line.count + 1
            }
            return kept
        }
    }

    /// Splits transcript lines into parts of at most `maxChars`, cutting only between lines (each line is one
    /// complete utterance) and repeating the last ~`overlapChars` of a part at the start of the next.
    static func chunkLines(_ lines: [String], maxChars: Int, overlapChars: Int) -> [[String]] {
        var parts: [[String]] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > maxChars, !current.isEmpty {
                parts.append(current)
                var overlap: [String] = []
                var overlapSize = 0
                for l in current.reversed() where overlapSize + l.count <= overlapChars {
                    overlap.insert(l, at: 0)
                    overlapSize += l.count + 1
                }
                current = overlap
                size = overlapSize
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    func summarize(_ id: String, store: Store) async throws {
        guard let m = store.meeting(id) else { return }
        try store.setStatus(id, "processing:summarizing")
        let n = try await Self.draftNotes(m, store: store) { part in try? store.setStatus(id, "processing:summarizing \(part)") }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        try await store.db.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return }
            if let t = n.title, !t.isEmpty { meeting.title = t }
            meeting.summary = n.overview ?? ""
            meeting.status = "done"
            meeting.modifiedAt = .now
            try meeting.update(db)
            try db.execute(sql: "DELETE FROM insights WHERE meeting_id = ?", arguments: [id])
            for (i, x) in (n.insights ?? []).enumerated() {
                var ins = Insight(meetingId: id, text: x.text, time: parseTimestamp(x.time), sortOrder: i)
                try ins.insert(db)
            }
            // Keep items the user already ticked off; regenerate the rest.
            try db.execute(sql: "DELETE FROM action_items WHERE meeting_id = ? AND completed = 0", arguments: [id])
            for a in n.action_items ?? [] {
                var item = ActionItem(meetingId: id, text: a.text, assignee: a.assignee.flatMap { $0 == "null" || $0.isEmpty ? nil : $0 },
                                      dueDate: a.due.flatMap { day.date(from: $0) })
                try item.insert(db)
            }
            for t in n.tags ?? [] { try Store.attach(tag: t, to: id, db) }
        }
        MarkdownExport.autoExport(id, store: store)
    }

    // MARK: - ASR

    struct Word { var text: String; var start: Double; var end: Double; var speaker: String; var overlap = false
        init(w: WordTiming, speaker: String) { text = w.word; start = w.startTime; end = w.endTime; self.speaker = speaker }
        init(_ text: String, _ start: Double, _ end: Double, _ speaker: String) { (self.text, self.start, self.end, self.speaker) = (text, start, end, speaker) }
    }
    struct Utterance { var speaker: String; var start: Double; var end: Double; var text: String; var overlap = false }

    /// Splits a word stream into readable turns: new turn on speaker change, a pause, or a long run.
    static func utterances(_ words: [Word]) -> [Utterance] {
        var out: [Utterance] = []
        var overlapping: [Int] = []  // per turn: words spoken over by another voice
        for w in words {
            if var last = out.last, last.speaker == w.speaker, w.start - last.end < 1.2,
               w.end - last.start < 40, !(w.end - last.start > 20 && ".?!".contains(last.text.last ?? " ")) {
                last.text += " " + w.text
                last.end = w.end
                out[out.count - 1] = last
                overlapping[out.count - 1] += w.overlap ? 1 : 0
            } else {
                out.append(Utterance(speaker: w.speaker, start: w.start, end: w.end, text: w.text))
                overlapping.append(w.overlap ? 1 : 0)
            }
        }
        // One overlapping word is usually just the handover between speakers.
        for i in out.indices where overlapping[i] >= 2 { out[i].overlap = true }
        return out
    }

    // MARK: - Echo

    /// Without headphones the mic hears the speakers. Dedupe on text, not DSP:
    /// drop a mic turn that mostly repeats a system turn at the same time.
    static func dropEchoes(mic: [Utterance], system: [Utterance]) -> [Utterance] {
        let sys = system.map { ($0, tokens($0.text)) }
        return mic.filter { m in
            let t = tokens(m.text)
            guard !t.isEmpty else { return true }
            return !sys.contains { s, st in
                s.start < m.end + 3 && m.start < s.end + 3 && Double(t.intersection(st).count) / Double(t.union(st).count) >= 0.5
            }
        }
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
    }

    // MARK: - Diarization + persistent voices

    struct Label { let speaker: String; let start: Double; let end: Double }

    /// The speaker of a word: the diarization segment covering most of it (the nearest one if none does),
    /// and whether another voice covers at least half of it too — people talking at the same time.
    static func label(_ start: Double, _ end: Double, in labels: [Label]) -> (speaker: String, overlap: Bool)? {
        guard !labels.isEmpty else { return nil }
        let mid = (start + end) / 2, half = max(end - start, 0.05) / 2
        let (a, b) = (mid - half, mid + half)
        var cover: [String: Double] = [:]
        for l in labels where l.start < b && a < l.end { cover[l.speaker, default: 0] += min(b, l.end) - max(a, l.start) }
        if let best = cover.max(by: { $0.value < $1.value }) {
            return (best.key, cover.contains { $0.key != best.key && $0.value >= half })
        }
        let nearest = labels.min { min(abs($0.start - mid), abs($0.end - mid)) < min(abs($1.start - mid), abs($1.end - mid)) }!
        return (nearest.speaker, false)
    }

    struct KnownVoice { let id: String; let person: String; let voices: [[Float]] }

    /// Matches this meeting's speakers (clusters) to known voices, best pairs first, with at most one speaker
    /// per person (merged speakers count as one person): two voices from one meeting never become one person.
    static func assignVoices(_ clusters: [String: [Float]], known: [KnownVoice], threshold: Float) -> [String: (id: String, score: Float)] {
        var pairs: [(cluster: String, known: Int, score: Float)] = []
        for (cluster, emb) in clusters {
            for (i, k) in known.enumerated() {
                let score = k.voices.map { cosine($0, emb) }.max() ?? -1
                if score >= threshold { pairs.append((cluster, i, score)) }
            }
        }
        var out: [String: (id: String, score: Float)] = [:]
        var people = Set<String>()
        for p in pairs.sorted(by: { $0.score > $1.score }) where out[p.cluster] == nil && !people.contains(known[p.known].person) {
            out[p.cluster] = (known[p.known].id, p.score)
            people.insert(known[p.known].person)
        }
        return out
    }

    /// Diarizes a track and maps each local cluster to a stored person by voice embedding,
    /// so someone renamed once keeps their name in later meetings.
    private func speakerLabels(_ url: URL, store: Store, meeting: Meeting?) async throws -> [Label] {
        if diarizerModels == nil { diarizerModels = try await OfflineDiarizerModels.load() }
        guard let diarizerModels else { return [] }
        var config = OfflineDiarizerConfig.default
        config.postProcessing.exclusiveSegments = false  // keep both voices where people talk at once
        config.zeroVoteReembed.enabled = true  // re-check spans that would silently join the neighbouring speaker
        if let n = meeting?.expectedSpeakers { config.clustering.numSpeakers = n }
        else if let n = meeting?.maxSpeakers { config.clustering.maxSpeakers = n }
        let diarizer = OfflineDiarizerManager(config: config)
        diarizer.initialize(models: diarizerModels)
        let result = try await diarizer.process(url)

        var sums: [String: [Float]] = [:]
        for s in result.segments where !s.embedding.isEmpty {
            sums[s.speakerId] = zip(sums[s.speakerId] ?? Array(repeating: 0, count: s.embedding.count), s.embedding).map { $0 + $1 }
        }
        let centroids = (result.speakerDatabase ?? sums).mapValues(Self.normalized)
        let threshold = Float(defaults.object(forKey: "voiceMatchThreshold") as? Double ?? 0.7)

        let mapping: [String: String] = try await store.db.write { db in
            let all = try Speaker.fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            var known = all.filter { $0.embeddingModel == Self.voiceModel && !$0.embedding.isEmpty }
            let voices = known.map { KnownVoice(id: $0.id, person: store.root($0.id, in: byID)?.id ?? $0.id, voices: [$0.embedding] + $0.voiceSamples) }
            let matches = Self.assignVoices(centroids, known: voices, threshold: threshold)
            var mapping: [String: String] = [:]
            var count = try Speaker.filter(sql: "name LIKE 'Speaker %'").fetchCount(db)
            for (cluster, emb) in centroids.sorted(by: { $0.key < $1.key }) {
                if let match = matches[cluster], let i = known.firstIndex(where: { $0.id == match.id }) {
                    // Only a confident match teaches the voice something new.
                    if match.score >= max(threshold, 0.8) {
                        known[i].voiceSamples = Array((known[i].voiceSamples + [emb]).suffix(5))
                        try known[i].update(db)
                    }
                    mapping[cluster] = match.id
                } else {
                    count += 1
                    let new = Speaker(id: UUID().uuidString, name: "Speaker \(count)", embedding: emb,
                                      embeddingModel: Self.voiceModel, createdAt: .now)
                    try new.insert(db)
                    mapping[cluster] = new.id
                }
            }
            return mapping
        }
        return result.segments.map {
            Label(speaker: mapping[$0.speakerId] ?? "", start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return zip(normalized(a), normalized(b)).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - AI cleanup

    func cleanup(_ id: String, store: Store) async {
        struct Fixed: Decodable { let text: String; let irrelevant: Bool? }
        let custom = defaults.string(forKey: "cleanupPrompt") ?? ""
        let system = (custom.isEmpty ? Prompts.defaultCleanup : custom) + "\n" + Prompts.cleanupFormat
        guard let segs = try? store.segments(of: id).filter({ !$0.userEdited }) else { return }
        for start in stride(from: 0, to: segs.count, by: 25) {
            let batch = Array(segs[start..<min(start + 25, segs.count)])
            let input = batch.enumerated().map { "\($0.offset + 1). \($0.element.originalText ?? $0.element.text)" }.joined(separator: "\n")
            // Best effort: a bad batch keeps the raw text.
            guard let fixed = try? await LLM.current.json([Fixed].self, system: system, user: input), fixed.count == batch.count else { continue }
            try? await store.db.write { db in
                for (s, f) in zip(batch, fixed) where !f.text.isEmpty || f.irrelevant == true {
                    try db.execute(
                        sql: "UPDATE segments SET original_text = COALESCE(original_text, text), text = ?, irrelevant = ? WHERE id = ?",
                        arguments: [f.text.isEmpty ? s.text : f.text, f.irrelevant ?? false, s.id])
                }
            }
        }
    }

    // MARK: - Semantic index

    /// Groups consecutive turns into ~120-word chunks and embeds them. Silently skipped if no embedding endpoint.
    func index(_ id: String, store: Store) async {
        guard let segs = try? store.segments(of: id).filter({ !$0.irrelevant }), !segs.isEmpty else { return }
        let all = (try? store.speakers()) ?? [:]
        var chunks: [Chunk] = []
        // Small chunks (≤ chunkWords): the model is trained on sentences, reads at most 128 tokens, and long mixed
        // chunks blur the vector.
        for s in segs {
            let name = store.root(s.speakerId, in: all)?.name ?? "Speaker"
            let words = s.text.split(separator: " ")
            let n = Self.chunkWords
            for piece in stride(from: 0, to: max(words.count, 1), by: n) {
                let line = "\(name): " + words[piece..<min(piece + n, words.count)].joined(separator: " ")
                if var last = chunks.last, last.text.split(separator: " ").count + min(n, words.count - piece) <= n {
                    last.text += "\n" + line
                    last.end = s.end
                    chunks[chunks.count - 1] = last
                } else {
                    chunks.append(Chunk(meetingId: id, start: s.start, end: s.end, text: line))
                }
            }
        }
        for b in stride(from: 0, to: chunks.count, by: 32) {
            let range = b..<min(b + 32, chunks.count)
            // Embed the words only: repeated "Speaker 1:" prefixes pull unrelated chunks together.
            let inputs = chunks[range].map { Self.embeddingText($0.text) }
            guard let vecs = (try? await Embedder.embed(inputs)) ?? nil, vecs.count == range.count else { break }
            for (i, v) in zip(range, vecs) { chunks[i].embedding = Self.normalized(v) }
        }
        let rows = chunks
        try? await store.db.write { db in
            try db.execute(sql: "DELETE FROM chunks WHERE meeting_id = ?", arguments: [id])
            for var c in rows { try c.insert(db) }
        }
    }

    /// Calibrated on MiniLM-L12 multilingual with 30-word chunks: related passages score ~0.43–0.57 (also across
    /// Russian/English), unrelated ones ≤ ~0.31.
    static let semanticMatch: Double = 0.38
    static func semanticScore(_ cosine: Double) -> Double { min(1, max(0, (cosine - 0.25) / 0.35)) }

    static let chunkWords = 30
    static let chunkVersion = "chunks-30w-noprefix"

    static func embeddingText(_ chunkText: String) -> String {
        chunkText.split(separator: "\n").map { line in
            line.range(of: ": ").map { String(line[$0.upperBound...]) } ?? String(line)
        }.joined(separator: " ")
    }

    // MARK: - Hybrid search

    struct SearchResult: Identifiable, Hashable {
        var id: String { meeting.id }
        let meeting: Meeting
        let score: Double
        let snippet: String
        let snippetTime: Double?
    }

    static func search(_ query: String, store: Store) async throws -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let hits = try store.keywordHits(q, limit: 200)
        let titles = try store.titleMatches(q)
        var kw: [String: (Double, Hit)] = [:]
        if let lo = hits.map(\.rank).min(), let hi = hits.map(\.rank).max() {
            for h in hits {  // bm25 is negative; more negative = better
                let norm = hi == lo ? 1 : (hi - h.rank) / (hi - lo)
                if (kw[h.meetingId]?.0 ?? -1) < norm { kw[h.meetingId] = (norm, h) }
            }
        }
        var sem: [String: (Double, Chunk)] = [:]
        if let qv = ((try? await Embedder.embed([q])) ?? nil)?.first {
            for c in try store.chunks() {
                let s = Double(cosine(qv, c.embedding ?? []))
                if (sem[c.meetingId]?.0 ?? -1) < s { sem[c.meetingId] = (s, c) }
            }
        }
        let ids = Set(kw.keys).union(titles).union(sem.filter { $0.value.0 >= Self.semanticMatch }.keys)
        return ids.compactMap { id -> SearchResult? in
            guard let m = store.meeting(id), m.deletedAt == nil else { return nil }
            let k = kw[id]?.0 ?? 0, s = Self.semanticScore(sem[id]?.0 ?? 0)
            // The stronger signal leads; agreement of both pushes towards 100%.
            let score = min(1, 0.7 * max(k, s) + 0.3 * min(k, s) + (titles.contains(id) ? 0.2 : 0))
            var snippet = m.summary, time: Double? = nil
            if let h = kw[id]?.1 { (snippet, time) = (h.text, h.start) } else if let c = sem[id]?.1 { (snippet, time) = (c.text, c.start) }
            return SearchResult(meeting: m, score: score, snippet: snippet, snippetTime: time)
        }.sorted { $0.score > $1.score }
    }

    /// "Related meetings": closeness of meeting embeddings, boosted by shared tags and people.
    static func similar(to id: String, store: Store) throws -> [(Meeting, Double)] {
        let chunks = try store.chunks()
        var sums: [String: [Float]] = [:]
        for c in chunks { if let e = c.embedding { sums[c.meetingId] = zip(sums[c.meetingId] ?? Array(repeating: 0, count: e.count), e).map { $0 + $1 } } }
        let tags = try store.tagsByMeeting().mapValues { Set($0.map(\.id)) }
        let mine = sums[id], myTags = tags[id] ?? []
        let myPeople = Set(try store.participants(of: id).map(\.id)).subtracting([Speaker.meID])
        return try store.meetings(.all).filter { $0.id != id }.compactMap { m in
            let base = mine.flatMap { a in sums[m.id].map { Double(cosine(a, $0)) } } ?? 0
            let sharedTags = Double(myTags.intersection(tags[m.id] ?? []).count)
            let sharedPeople = Double(myPeople.intersection(try store.participants(of: m.id).map(\.id)).count)
            let score = base + 0.08 * sharedTags + 0.05 * sharedPeople
            return score > 0.5 ? (m, min(score, 1)) : nil
        }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
    }

    // MARK: - Chat (RAG with citations, @mentions, time ranges)

    struct Mentions { var speakers: [Speaker] = []; var tags: [Tag] = []; var meetings: [Meeting] = [] }

    /// `@Name`, `@tag`, `@'Meeting title'` → people, tags or meetings that narrow the scope.
    static func mentions(in text: String, store: Store) throws -> Mentions {
        var out = Mentions()
        let people = try store.people().map(\.0)
        let tags = try store.allTags().map(\.0)
        let meetings = try store.meetings(.all)
        let quoted = try NSRegularExpression(pattern: #"@['"“‘]([^'"”’]+)['"”’]"#)
        for m in quoted.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let title = (text as NSString).substring(with: m.range(at: 1)).lowercased()
            out.meetings += meetings.filter { $0.title.lowercased().contains(title) }
        }
        let plain = try NSRegularExpression(pattern: #"@([\p{L}\p{N}_\-\.]+)"#)
        for m in plain.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let word = (text as NSString).substring(with: m.range(at: 1)).lowercased()
            if let p = people.first(where: { $0.name.lowercased() == word || $0.name.lowercased().hasPrefix(word + " ") }) { out.speakers.append(p) }
            else if let t = tags.first(where: { $0.name == word }) { out.tags.append(t) }
        }
        return out
    }

    /// Time cues inside one recording ("at the end", "first 10 minutes", "около 20-й минуты").
    static func timeRange(_ question: String, duration d: Double) -> ClosedRange<Double>? {
        let q = question.lowercased()
        func match(_ p: String) -> [Double]? {
            guard let r = try? NSRegularExpression(pattern: p),
                  let m = r.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) else { return nil }
            // Alternations leave the other branch's groups unmatched (location == NSNotFound).
            return (1..<m.numberOfRanges).map { m.range(at: $0) }.filter { $0.location != NSNotFound }
                .compactMap { Double((q as NSString).substring(with: $0)) }
        }
        if let n = match(#"(?:from )?minutes? (\d+) (?:to|through|-) (?:minute )?(\d+)|с (\d+)[^\d]{1,12}по (\d+) мин"#), n.count == 2 {
            return n[0] * 60...max(n[0], n[1]) * 60
        }
        if let n = match(#"first (\d+) min|перв\w* (\d+) мин"#)?.first { return 0...min(d, n * 60) }
        if let n = match(#"last (\d+) min|последн\w* (\d+) мин"#)?.first { return max(0, d - n * 60)...d }
        if let n = match(#"minute (\d+)|(\d+)(?:-?й|-?ой)? минут"#)?.first { return max(0, n * 60 - 120)...n * 60 + 120 }
        if q.contains("beginning") || q.contains("начал") { return 0...d * 0.25 }
        if q.contains("middle") || q.contains("середин") { return d * 0.25...d * 0.75 }
        if q.contains("the end") || q.contains("конце") || q.contains("в конц") { return d * 0.75...d }
        return nil
    }

    static func answer(_ question: String, session: ChatSession, history: [ChatMessage], store: Store) async throws -> (String, [Citation]) {
        let all = try store.speakers()
        let mentions = try mentions(in: question, store: store)
        var scope: [String]? = session.meetingId.map { [$0] }
        if !mentions.meetings.isEmpty { scope = mentions.meetings.map(\.id) }
        if !mentions.tags.isEmpty {
            scope = try mentions.tags.flatMap { try store.meetings(.tag($0.id)).map(\.id) }
        }
        let speakerIDs = try Set(mentions.speakers.flatMap { p in
            try store.db.read { try String.fetchAll($0, sql: Store.familySQL, arguments: [p.id]) }
        })
        func keep(_ speakerID: String?) -> Bool { speakerIDs.isEmpty || speakerID.map(speakerIDs.contains) == true }

        var excerpts: [Citation] = []
        // One meeting whose transcript fits goes in whole; a longer one falls back to retrieval within it.
        var fullFits = false
        if let ids = scope, ids.count == 1 {
            let size = try store.segments(of: ids[0]).reduce(0) { $0 + $1.text.count + 20 }
            fullFits = size < LLM.current.maxInputChars - 10_000
        }
        if fullFits, let ids = scope, let m = store.meeting(ids[0]) {
            let range = timeRange(question, duration: m.duration)
            let segs = try store.segments(of: m.id).filter { !$0.irrelevant && keep($0.speakerId) && (range?.contains($0.start) ?? true) }
            excerpts = segs.map {
                Citation(meetingId: m.id, title: m.title, start: $0.start, end: $0.end,
                         text: "\(store.root($0.speakerId, in: all)?.name ?? "Speaker"): \($0.text)")
            }
        } else {
            let hits = try store.keywordHits(question, meetingIDs: scope, limit: 40).filter { _ in speakerIDs.isEmpty }
            excerpts = hits.map { Citation(meetingId: $0.meetingId, title: $0.title, start: $0.start, end: $0.end, text: "\($0.name ?? "Speaker"): \($0.text)") }
            if let qv = ((try? await Embedder.embed([question])) ?? nil)?.first {
                let top = try store.chunks(meetingIDs: scope).map { ($0, cosine(qv, $0.embedding ?? [])) }
                    .sorted { $0.1 > $1.1 }.prefix(12)
                for (c, _) in top where !excerpts.contains(where: { $0.meetingId == c.meetingId && abs($0.start - c.start) < 5 }) {
                    excerpts.append(Citation(meetingId: c.meetingId, title: store.meeting(c.meetingId)?.title ?? "", start: c.start, end: c.end, text: c.text))
                }
            }
            if !speakerIDs.isEmpty {
                let ids = try scope ?? store.meetings(.all).map(\.id)
                for id in ids.prefix(30) {
                    guard let m = store.meeting(id) else { continue }
                    excerpts += try store.segments(of: id).filter { !$0.irrelevant && keep($0.speakerId) }.map {
                        Citation(meetingId: id, title: m.title, start: $0.start, end: $0.end,
                                 text: "\(store.root($0.speakerId, in: all)?.name ?? "Speaker"): \($0.text)")
                    }
                }
                excerpts = Array(excerpts.prefix(300))
            }
        }
        guard !excerpts.isEmpty else { return ("I couldn't find anything relevant in your meetings for that question.", []) }

        let context = excerpts.enumerated().map { "[\($0.offset + 1)] (\($0.element.title), \(timestamp($0.element.start))) \($0.element.text)" }
            .joined(separator: "\n")
        var messages: [[String: String]] = [["role": "system", "content": Prompts.chat + "\n\nExcerpts:\n" + context]]
        for msg in history.suffix(6) { messages.append(["role": msg.role, "content": msg.content]) }
        messages.append(["role": "user", "content": question])
        let reply = try await LLM.current.chat(messages: messages)
        return (reply, excerpts)
    }
}
