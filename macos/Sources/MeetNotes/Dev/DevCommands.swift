import EventKit
import GRDB
import os
import SwiftUI

/// Command-line modes for checking the app without the UI (`MeetNotes --selftest`, `--mcp-test …`, see README).
/// Each mode prints its result and exits; without a flag this does nothing and the app starts normally.
enum DevCommands {
    static func runIfRequested() {
        if CommandLine.arguments.contains("--selftest") { Pipeline.selfTest(); exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe-test") {
            // `--transcribe-test [file] [-transcriptionEngine openai | -localSpeechModel whisper-tiny]`: checks the configured
            // engine, or transcribes a file with it (downloading the chosen local model first).
            let file = CommandLine.arguments.dropFirst(i + 1).first.flatMap { $0.hasPrefix("-") ? nil : $0 }
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    if let id = UserDefaults.standard.string(forKey: "localSpeechModel"), let m = SpeechModels.find(id), !m.isDownloaded {
                        print("downloading \(m.name) (\(m.sizeLabel))…")
                        let shown = OSAllocatedUnfairLock(initialState: -1)
                        try await m.download(progress: { p in
                            let pct = Int(p * 100)
                            if shown.withLock({ last in defer { last = max(last, pct / 10) }; return pct / 10 > last }) { print("\(pct)%") }
                        }, preparing: { print("compiling for this Mac…") })
                    }
                } catch { print("download failed: \(error.localizedDescription)") }
                let engine = TranscriptionEngines.current
                do {
                    if let file {
                        let words = try await engine.words(URL(filePath: file)) { print("part \($0)/\($1)") }
                        print(words.map { "[\(timestamp($0.startTime))] \($0.word)" }.joined(separator: "\n"))
                    } else if let cloud = engine as? CloudTranscriber {
                        try await cloud.check()
                    }
                    print("\(engine.name): ok")
                } catch { print("\(engine.name): \(error.localizedDescription)") }
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--embed-test") {
            // Downloads (first time) and runs the built-in embedding model on a few known pairs.
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                let texts = ["We need to cut the budget for next quarter.", "Нам нужно сократить бюджет на следующий квартал.",
                             "Money for Q3 will be reduced.", "The cat is sleeping on the sofa.", "Кошка спит на диване."]
                do {
                    let t0 = Date()
                    let v = try await LocalEmbedder.shared.embed(texts).map(Pipeline.normalized)
                    let t1 = Date()
                    _ = try await LocalEmbedder.shared.embed(Array(repeating: texts[0], count: 32))
                    print(String(format: "embed-test: dim=%d load+5 texts %.1fs, 32 texts %.2fs", v[0].count, t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)))
                    print("  tokens(Hello world) = \(try await LocalEmbedder.shared.tokenIDs("Hello world")) (XLM-R reference: [0, 35378, 8999, 2])")
                    print("  " + (try await LocalEmbedder.shared.poolingDescription()))
                    for (a, b) in [(0, 1), (0, 2), (3, 4), (0, 3), (1, 4)] {
                        print(String(format: "  %.3f  %@  ↔  %@", Pipeline.cosine(v[a], v[b]), texts[a], texts[b]))
                    }
                } catch { print("embed-test failed: \(error)") }
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
            // Hybrid search from the command line against the real library (read-only).
            let q = CommandLine.arguments[i + 1]
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let store = try Store()
                    if CommandLine.arguments.contains("--raw"), let qv = try await Embedder.embed([q])?.first {
                        for (c, sim) in try store.chunks().map({ ($0, Pipeline.cosine(qv, $0.embedding ?? [])) }).sorted(by: { $0.1 > $1.1 }).prefix(3) {
                            print(String(format: "  raw %.3f  [%@] %@", sim, timestamp(c.start), String(c.text.prefix(90)).replacingOccurrences(of: "\n", with: " ")))
                        }
                    }
                    for r in try await Pipeline.search(q, store: store).prefix(5) {
                        print(String(format: "%3d%%  %@  [%@]  %@", Int(r.score * 100), r.meeting.title, timestamp(r.snippetTime ?? 0), String(r.snippet.prefix(110))))
                    }
                } catch { print("search failed: \(error)") }
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--summary-test"), i + 1 < CommandLine.arguments.count {
            // Prints the summary the current provider would write for a meeting; nothing is saved.
            let id = CommandLine.arguments[i + 1]
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let store = try Store()
                    guard let m = store.meeting(id) else { throw LLMError(message: "No meeting \(id)") }
                    let t0 = Date()
                    let n = try await Pipeline.draftNotes(m, store: store) { print("  map part \($0)") }
                    print(String(format: "summary-test via %@ %@ in %.0fs", LLM.current.baseURL, LLM.current.model, Date().timeIntervalSince(t0)))
                    print("title: \(n.title ?? "-")\noverview: \(n.overview ?? "-")")
                    for x in n.insights ?? [] { print("insight [\(x.time ?? "")]: \(x.text)") }
                    for a in n.action_items ?? [] { print("action: \(a.text) — \(a.assignee ?? "?") \(a.due ?? "")") }
                    print("tags: \((n.tags ?? []).joined(separator: ", "))")
                } catch { print("summary-test failed: \(error.localizedDescription)") }
                await LlamaEngine.shared.unload()
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--calendar-request"), i + 1 < CommandLine.arguments.count {
            // Requests access with a store created *before* the grant, then compares it with a fresh store.
            let early = EKEventStore()
            let sema = DispatchSemaphore(value: 0)
            var granted = false
            early.requestFullAccessToEvents { ok, _ in granted = ok; sema.signal() }
            sema.wait()
            let fresh = EKEventStore()
            let line = "granted=\(granted) status=\(EKEventStore.authorizationStatus(for: .event).rawValue) "
                + "earlyStoreCalendars=\(early.calendars(for: .event).count) freshStoreCalendars=\(fresh.calendars(for: .event).count)"
            try? line.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--calendar-diag"), i + 1 < CommandLine.arguments.count {
            // Writes calendar access state and counts to a file (launch via `open` so macOS checks Keepword' own permission).
            let store = EKEventStore()
            let status = EKEventStore.authorizationStatus(for: .event)
            var lines = ["status=\(status.rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 fullAccess, 4 writeOnly)"]
            if status == .fullAccess {
                let cals = store.calendars(for: .event)
                lines.append("calendars=\(cals.count): " + cals.map { "\($0.title) [\($0.source.title)]" }.joined(separator: ", "))
                let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(-7 * 86400)
                let events = store.events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(28 * 86400), calendars: nil))
                lines.append("events next 4 weeks=\(events.count), all-day=\(events.filter(\.isAllDay).count), with video link=\(events.filter { CalEvent($0).videoLink != nil }.count)")
            }
            try? lines.joined(separator: "\n").write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ics-test"), i + 1 < CommandLine.arguments.count {
            // Fetches and parses a calendar feed URL and prints a summary (no data is stored).
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let (data, _) = try await URLSession.shared.data(from: URL(string: CommandLine.arguments[i + 1])!)
                    let text = String(decoding: data, as: UTF8.self)
                    let now = Date.now
                    let evs = ICS.parse(text, calendarName: "test", color: .blue, from: now.addingTimeInterval(-90 * 86400), to: now.addingTimeInterval(365 * 86400))
                    print("ics-test: \(text.components(separatedBy: "BEGIN:VEVENT").count - 1) VEVENTs, \(evs.count) events in window, all-day \(evs.filter(\.isAllDay).count)")
                    for e in evs.filter({ $0.start > now }).prefix(5) { print("  \(e.start.formatted(date: .abbreviated, time: .omitted))  \(e.title)") }
                } catch { print("ics-test failed: \(error.localizedDescription)") }
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--mcp-test"), i + 1 < CommandLine.arguments.count {
            // Connects to an MCP server (`--mcp-test <command> <args…>`; env is inherited), lists tools, tries one call.
            var cfg = MCPServerConfig()
            cfg.name = "test"
            cfg.command = CommandLine.arguments[i + 1]
            cfg.args = Array(CommandLine.arguments[(i + 2)...])
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                let client = MCPClient(config: cfg)
                do {
                    let t0 = Date()
                    let tools = try await client.tools()
                    print(String(format: "mcp-test: %d tools in %.1fs; task tool: %@", tools.count, Date().timeIntervalSince(t0), TaskMapping.suggestTaskTool(tools) ?? "none"))
                    if let create = tools.first(where: { $0.name == TaskMapping.suggestTaskTool(tools) }) {
                        print("  required: \(create.required), lookups: " + create.properties.keys.sorted().compactMap { k in
                            TaskMapping.lookupTool(for: k, in: tools).map { "\(k)→\($0.name)" } }.joined(separator: ", "))
                        // The sheet's flow: pick space → board from lookups, then create one task.
                        do {
                            var shared: [String: String] = [:]
                            for key in ["space_id", "board_id"] {
                                guard let lookup = TaskMapping.lookupTool(for: key, in: tools) else { continue }
                                var args: [String: Any] = [:]
                                for (k, v) in shared where lookup.properties[k] != nil { args[k] = Int(v) ?? v }
                                let opts = TaskMapping.options(from: try await client.call(lookup.name, args))
                                print("  \(lookup.name)\(args): \(opts.prefix(5))")
                                shared[key] = opts.first?.0
                            }
                            let draft = TaskMapping.Draft(title: "Send the report", details: "From meeting", due: Date(timeIntervalSince1970: 1_793_000_000))
                            let args = TaskMapping.arguments(for: draft, tool: create, shared: shared)
                            print("  args: \(args)")
                            let result = try await client.call(create.name, args)
                            print("  created: \(result.prefix(300))\n  link: \(TaskMapping.link(in: result) ?? "none")")
                        } catch { print("  call error: \(error.localizedDescription.prefix(300))") }
                    }
                } catch { print("mcp-test failed: \(error.localizedDescription)") }
                await client.stop()
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--process"), i + 1 < CommandLine.arguments.count {
            // Re-runs transcription + diarization of a meeting without the UI and prints who spoke when.
            // Use on a copy: `-libraryPath <dir> -autoSummarize NO -aiCleanup NO [-expectedSpeakers N]`.
            if let path = UserDefaults.standard.string(forKey: "libraryPath"), !path.isEmpty { Store.dataDir = URL(filePath: path) }
            let id = CommandLine.arguments[i + 1]
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let store = try Store()
                    if store.meeting(id) == nil {  // audio dropped into recordings/<id>/ by hand
                        var m = Meeting.new(title: id)
                        m.id = id
                        m.status = "queued"
                        try store.save(m)
                    }
                    let n = UserDefaults.standard.integer(forKey: "expectedSpeakers")  // `-expectedSpeakers N`, as in Re-identify
                    if n > 0 { try store.update(id) { $0.expectedSpeakers = n } }
                    let t0 = Date()
                    await Pipeline.shared.process(id, store: store)
                    let segs = try store.segments(of: id)
                    let names = try store.speakers().mapValues(\.name)
                    print(String(format: "process: %@ in %.0fs, %d blocks, %d with overlapping voices",
                                 store.meeting(id)?.status ?? "?", Date().timeIntervalSince(t0), segs.count, segs.filter(\.overlap).count))
                    for (who, n) in Dictionary(grouping: segs, by: { $0.speakerId.flatMap { names[$0] } ?? "—" }).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
                        print("  \(who): \(n) blocks")
                    }
                } catch { print("process failed: \(error)") }
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--llm-test") {
            // One JSON round-trip through the configured provider (override with -llmBaseURL / -llmModel).
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                struct R: Decodable { let ok: Bool; let lang: String }
                do {
                    let llm = LLM.current
                    let r = try await llm.json(R.self, system: "You are a JSON API. Reply with JSON only.",
                                               user: "Return {\"ok\": true, \"lang\": \"<ISO code of: Привет, как дела?>\"}")
                    print("llm-test ok via \(llm.baseURL) \(llm.model): ok=\(r.ok) lang=\(r.lang)")
                } catch { print("llm-test failed: \(error.localizedDescription)") }
                await LlamaEngine.shared.unload()
                sema.signal()
            }
            sema.wait()
            exit(0)
        }
    }
}
