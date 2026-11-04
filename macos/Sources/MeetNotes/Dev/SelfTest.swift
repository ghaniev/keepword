import AVFoundation
import FluidAudio
import Foundation
import GRDB

extension Pipeline {
    static func selfTest() {
        let ws = [Word("Hello", 0, 0.5, "a"), Word("there.", 0.6, 1, "a"), Word("Hi", 1.2, 1.5, "b"), Word("again", 5, 5.5, "b")]
        precondition(utterances(ws).map(\.text) == ["Hello there.", "Hi", "again"])

        let sys = [Utterance(speaker: "x", start: 10, end: 14, text: "we ship the release on friday")]
        let mic = [Utterance(speaker: "me", start: 10.4, end: 14.2, text: "we ship the release on Friday"),
                   Utterance(speaker: "me", start: 11, end: 13, text: "sounds good to me")]
        precondition(dropEchoes(mic: mic, system: sys).map(\.text) == ["sounds good to me"])

        let labels = [Label(speaker: "s1", start: 0, end: 2), Label(speaker: "s2", start: 3, end: 5)]
        precondition(label(0.9, 1.1, in: labels)! == ("s1", false) && label(2.7, 2.9, in: labels)!.speaker == "s2")
        // Word mostly inside s2 goes to s2 (midpoint-first used to give it to s1); overlapping voices are flagged.
        let both = [Label(speaker: "s1", start: 0, end: 10), Label(speaker: "s2", start: 4, end: 6)]
        precondition(label(1.8, 2.6, in: [Label(speaker: "s1", start: 0, end: 2), Label(speaker: "s2", start: 2, end: 5)])!.speaker == "s2")
        precondition(label(4.5, 5.0, in: both)!.overlap && !label(1, 1.5, in: both)!.overlap)
        let ow = [Word("a", 0, 0.3, "x"), Word("b", 0.4, 0.7, "x"), Word("c", 0.8, 1.0, "x")]
        var ow2 = ow; ow2[1].overlap = true; ow2[2].overlap = true
        precondition(!utterances({ var w = ow; w[2].overlap = true; return w }())[0].overlap && utterances(ow2)[0].overlap)
        // Two meeting voices both close to one known person: only the closer one becomes that person.
        let anna = KnownVoice(id: "anna", person: "anna", voices: [[1, 0, 0]])
        let annaWork = KnownVoice(id: "anna-work", person: "anna", voices: [[0.9, 0.1, 0]])  // merged into anna
        let bob = KnownVoice(id: "bob", person: "bob", voices: [[0, 1, 0]])
        let m = assignVoices(["c1": [1, 0.05, 0], "c2": [0.95, 0.15, 0], "c3": [0, 0, 1]], known: [anna, annaWork, bob], threshold: 0.7)
        precondition([m["c1"], m["c2"]].compactMap { $0 }.count == 1 && m["c3"] == nil)  // one voice per person
        precondition(assignVoices(["c": [0.2, 1, 0]], known: [KnownVoice(id: "b", person: "b", voices: [[1, 0, 0], [0, 1, 0]])], threshold: 0.7)["c"]?.id == "b")
        precondition(abs(cosine([1, 0], [2, 0]) - 1) < 1e-6 && cosine([1, 0], [0, 1]) == 0)

        precondition(embeddingText("Anna: we ship\nSpeaker 2: ok: fine") == "we ship ok: fine")
        precondition(semanticScore(0.2) == 0 && semanticScore(0.6) == 1 && abs(semanticScore(0.425) - 0.5) < 1e-9)
        precondition([8, 16, 24, 32, 48, 96].map { LocalModels.recommended(forRAM: $0).id }
                      == ["qwen3.5-4b", "qwen3.5-4b", "qwen3.5-9b", "qwen3.5-9b", "qwen3.6-27b", "qwen3.6-27b"])
        precondition(LLM(baseURL: LocalModels.providerURL, model: "qwen3.5-4b", apiKey: "").maxInputChars == Int(Double(16_384 - 5_000) * 3.5))
        precondition(LLM(baseURL: "https://api.openai.com/v1", model: "x", apiKey: "").maxInputChars == 60_000)
        // Cloud transcription: Whisper's bare words get the text's punctuation; parts are cut in a pause.
        let bare = [WordTiming(word: "привет", startTime: 0, endTime: 0.4), WordTiming(word: "как", startTime: 0.5, endTime: 0.7),
                    WordTiming(word: "дела", startTime: 0.8, endTime: 1)]
        precondition(CloudTranscriber.punctuated(bare, from: "Привет! Как — дела?").map(\.word) == ["Привет!", "Как", "дела?"])
        let spread = CloudTranscriber.spread("one three", over: 10...18)
        precondition(spread.count == 2 && spread[0].startTime == 10 && abs(spread[1].startTime - 13.2) < 1e-9)
        let sr = Int(SpeechAudio.sampleRate)
        var tone = (0..<(sr * 25)).map { Float(sin(Double($0) * 0.3) * 0.2) }
        for i in (sr * 19)..<(sr * 19 + sr / 2) { tone[i] = 0 }  // a pause at 19 s
        let cuts = SpeechAudio.parts(tone, maxSeconds: 20)
        precondition(cuts.count == 2 && cuts[0].upperBound > sr * 19 && cuts[0].upperBound < sr * 19 + sr / 2 && cuts[1].upperBound == tone.count)
        precondition(SpeechAudio.hasSound(tone[0..<sr]) && !SpeechAudio.hasSound(tone[(sr * 19)..<(sr * 19 + sr / 3)]))
        let encoded = try! CloudTranscriber.encode(tone[0..<(sr * 10)])
        precondition(encoded.ext == "m4a" && encoded.data.count < 100_000)  // 10 s of AAC, not 320 KB of WAV
        precondition(CloudTranscriber.wav(tone[0..<100]).count == 244)
        // On-device speech models: unique ids, Whisper files where WhisperKit's downloader puts them.
        precondition(Set(SpeechModels.catalog.map(\.id)).count == SpeechModels.catalog.count && SpeechModels.find(SpeechModels.defaultID) != nil)
        precondition(WhisperTranscriber.folder(SpeechModels.find("whisper-small")!).path.hasSuffix("models/argmaxinc/whisperkit-coreml/openai_whisper-small"))
        precondition(CloudTranscriber.errorText(Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)) == "Invalid API key")
        // Reasoning removal (cases from Meetily's tests).
        precondition((try? LLM.visibleAnswer("<think>plan</think>OK")) == "OK")
        precondition((try? LLM.visibleAnswer("<thinking>\nplan\n</thinking>\n\nOK")) == "OK")
        precondition((try? LLM.visibleAnswer("<think type=\"x\">a</think>B")) == "B")
        precondition((try? LLM.visibleAnswer("Answer</think>")) == "Answer")
        precondition((try? LLM.visibleAnswer("OK <think>cut off by the token lim")) == "OK")
        precondition((try? LLM.visibleAnswer("<think>only reasoning, never closed")) == nil)
        precondition((try? LLM.visibleAnswer("<think>x</think>   ")) == nil)
        precondition((try? LLM.visibleAnswer("Plain answer")) == "Plain answer")
        // Map-reduce chunking: parts respect the limit, overlap, and cover every line in order.
        let tl = (0..<40).map { "[\($0):00] Speaker: " + String(repeating: "word ", count: 18) }
        let parts = chunkLines(tl, maxChars: 1_000, overlapChars: 250)
        precondition(parts.count > 1 && parts.allSatisfy { $0.joined(separator: "\n").count <= 1_000 })
        precondition(zip(parts, parts.dropFirst()).allSatisfy { a, b in b.first.map(a.contains) == true })
        var seenLines = Set<String>()
        precondition(parts.flatMap { $0 }.filter { seenLines.insert($0).inserted } == tl)
        precondition(chunkLines(["short"], maxChars: 1_000, overlapChars: 250) == [["short"]])
        let trimmed = evenlyTrimmed(["## Part 1\n- a\n- b\n- c", "## Part 2\n- d\n- e\n- f"], limit: 30)
        precondition(trimmed == ["## Part 1", "- a", "## Part 2", "- d"])  // every part keeps its head
        let suite = UserDefaults(suiteName: "meetnotes-selftest-\(UUID().uuidString)")!
        suite.set("NO", forKey: "a"); suite.set(true, forKey: "b")
        precondition(!suite.flag("a", true) && suite.flag("b", false) && suite.flag("missing", true))
        // iCal (Google feed) parsing: recurrence, EXDATE, moved instance, time zone, all-day, cancelled, folding.
        let ics = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:weekly1
            DTSTART;TZID=Europe/Moscow:20261005T100000
            DTEND;TZID=Europe/Moscow:20261005T103000
            RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6
            EXDATE;TZID=Europe/Moscow:20261007T100000
            SUMMARY:Daily\\, sync
            DESCRIPTION:Join: https://meet.google.com/abc-defg-hij\\nAgenda
            ATTENDEE;CN="Doe, John";ROLE=REQ-PARTICIPANT:mailto:john@example.com
            ATTENDEE:mailto:anna@example.com
            END:VEVENT
            BEGIN:VEVENT
            UID:weekly1
            RECURRENCE-ID;TZID=Europe/Moscow:20261012T100000
            DTSTART;TZID=Europe/Moscow:20261012T120000
            DTEND;TZID=Europe/Moscow:20261012T123000
            SUMMARY:Daily sync (moved)
            END:VEVENT
            BEGIN:VEVENT
            UID:allday
            DTSTART;VALUE=DATE:20261009
            DTEND;VALUE=DATE:20261010
            SUMMARY:Offsite
            END:VEVENT
            BEGIN:VEVENT
            UID:cancelled
            DTSTART:20261009T090000Z
            DTEND:20261009T100000Z
            STATUS:CANCELLED
            SUMMARY:Gone
            END:VEVENT
            BEGIN:VEVENT
            UID:monthly
            DTSTART:20261013T150000Z
            DURATION:PT1H
            RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20261231T235959Z
            SUMMARY:Board mee
             ting
            END:VEVENT
            END:VCALENDAR
            """
        let iso = ISO8601DateFormatter()
        let evs = ICS.parse(ics, calendarName: "Google", color: .blue,
                            from: iso.date(from: "2026-10-01T00:00:00Z")!, to: iso.date(from: "2026-12-31T23:59:59Z")!)
        let daily = evs.filter { $0.title.hasPrefix("Daily") }
        precondition(daily.map { iso.string(from: $0.start) } == ["2026-10-05T07:00:00Z", "2026-10-12T09:00:00Z", "2026-10-14T07:00:00Z",
                                                                   "2026-10-19T07:00:00Z", "2026-10-21T07:00:00Z"], "\(daily.map(\.start))")
        precondition(daily[0].title == "Daily, sync" && daily[1].title == "Daily sync (moved)" && daily[0].end.timeIntervalSince(daily[0].start) == 1800)
        precondition(daily[0].videoLink?.host == "meet.google.com" && daily[0].attendees == ["Doe, John", "anna@example.com"])
        let board = evs.filter { $0.title == "Board meeting" }
        precondition(board.map { iso.string(from: $0.start) } == ["2026-10-13T15:00:00Z", "2026-11-10T15:00:00Z", "2026-12-08T15:00:00Z"])
        precondition(board.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
        precondition(evs.first { $0.title == "Offsite" }?.isAllDay == true && !evs.contains { $0.title == "Gone" })

        // Overlapping events sit side by side; a later non-overlapping one gets the full width.
        func ev(_ id: String, _ h1: Double, _ h2: Double) -> CalEvent {
            CalEvent(id: id, title: id, start: Date(timeIntervalSince1970: h1 * 3600), end: Date(timeIntervalSince1970: h2 * 3600))
        }
        let laid = Dictionary(uniqueKeysWithValues: ICS.lanes([ev("A", 9, 10), ev("B", 9.5, 10.5), ev("C", 10.5, 11)]).map { ($0.0.id, ($0.1, $0.2)) })
        precondition(laid["A"]! == (0, 2) && laid["B"]! == (1, 2) && laid["C"]! == (0, 1))
        precondition(parseTimestamp("03:20") == 200 && parseTimestamp("1:02:03") == 3723 && parseTimestamp("x") == nil)
        precondition(timeRange("What happened at the end?", duration: 400) == 300...400)
        precondition(timeRange("summarize the first 10 minutes", duration: 3600) == 0...600)
        precondition(timeRange("что было в последние 5 минут", duration: 3600) == 3300...3600)
        precondition(timeRange("what was said around minute 20", duration: 3600) == 1080...1320)
        precondition(timeRange("from minute 10 to minute 30", duration: 3600) == 600...1800)
        precondition(timeRange("what were the decisions", duration: 3600) == nil)

        // Database: migrations, template hierarchy, trash.
        Store.useTemporaryLibrary()
        defer { try? FileManager.default.removeItem(at: Store.dataDir) }
        do {
            let store = try Store()
            var m = Meeting.new(title: "Test"); m.status = "done"
            try store.save(m)
            let f = Folder(id: "f", name: "Clients", icon: "folder", color: "blue", templateId: "client")
            try store.saveFolder(f)
            let t1 = try store.template(for: m)?.id
            precondition(t1 == "general")
            try store.move(m.id, to: "f")
            let t2 = try store.template(for: store.meeting(m.id)!)?.id
            precondition(t2 == "client")
            try store.update(m.id) { $0.templateId = "tech" }
            let t3 = try store.template(for: store.meeting(m.id)!)?.id
            precondition(t3 == "tech")
            try store.addTag("Kubernetes", to: m.id)
            let tags = try store.tags(of: m.id).map(\.name)
            precondition(tags == ["kubernetes"])
            try store.trash(m.id)
            let live = try store.meetings(.all).count, deleted = try store.meetings(.deleted).count
            precondition(live == 0 && deleted == 1)
            try store.restore(m.id)

            // TrackWriter: a device switch converts the new format and fills the gap with silence.
            let trackURL = Store.dataDir.appending(path: "track-test.caf")
            let f48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let f44 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            do {
                let w = try TrackWriter(url: trackURL, format: f48)
                let b1 = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 48_000)!; b1.frameLength = 48_000
                w.write(b1)
                w.markGap()
                Thread.sleep(forTimeInterval: 0.5)
                let b2 = AVAudioPCMBuffer(pcmFormat: f44, frameCapacity: 44_100)!; b2.frameLength = 44_100
                w.write(b2)
            }
            let seconds = try { let f = try AVAudioFile(forReading: trackURL); return Double(f.length) / f.fileFormat.sampleRate }()
            precondition(abs(seconds - 2.5) < 0.1, "track length \(seconds)")

            // Attachments: unique names, removal deletes the file.
            let tmp = FileManager.default.temporaryDirectory.appending(path: "meetnotes-att-\(UUID().uuidString).png")
            try Data([0x89, 0x50]).write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let a1 = try store.attach(file: tmp, to: m.id, recordingTime: 12)
            let a2 = try store.attach(file: tmp, to: m.id)
            precondition(a1.fileName != a2.fileName && a1.isImage && FileManager.default.fileExists(atPath: a1.url.path))
            try store.removeAttachment(a1)
            precondition(!FileManager.default.fileExists(atPath: a1.url.path))
            try? FileManager.default.removeItem(at: m.folder)

            // Speakers needing names, and merge resolution.
            let auto = Speaker(id: "s1", name: "Speaker 1", embedding: [], embeddingModel: "", createdAt: .now)
            try store.saveSpeaker(auto)
            try store.db.write { db in
                var seg = Segment(meetingId: m.id, speakerId: "s1", source: "system", start: 0, end: 5, text: "We ship on Friday")
                try seg.insert(db)
            }
            let unnamed1 = try store.unnamedSpeakers(in: m.id).map(\.id)
            precondition(unnamed1 == ["s1"])
            let anna = try store.newPerson(named: "Anna")
            try store.merge("s1", into: anna.id)
            let unnamed2 = try store.unnamedSpeakers(in: m.id), names = try store.participants(of: m.id).map(\.name)
            precondition(unnamed2.isEmpty && names == ["Anna"])

            // Live queries: schedule and evidence.
            var q = SavedQuery(id: "q", name: "Weekly", prompt: "Decisions?", schedule: "weekly", hour: 9, weekday: 2)
            let monday8 = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 8, weekday: 2), matchingPolicy: .nextTime)!
            precondition(q.nextRun(after: monday8) == monday8.addingTimeInterval(3600))
            q.schedule = "manual"
            precondition(q.nextRun(after: .now) == nil)
            try store.update(m.id) { $0.summary = "Shipping plan agreed." }
            try store.db.write { db in var i = Insight(meetingId: m.id, text: "Ship Friday", time: 3, sortOrder: 0); try i.insert(db) }
            let (ev, cites, count) = try LiveQueries.evidence(q, store: store)
            precondition(count == 1 && cites.count == 2 && ev.contains("[2] Ship Friday") && cites[1].start == 3)

            // HTTP parsing and MCP JSON-RPC.
            let raw = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nAuthorization: Bearer t\r\n\r\n{}".utf8)
            let req = HTTPRequest.parse(raw)
            precondition(req?.method == "POST" && req?.path == "/mcp" && req?.headers["authorization"] == "Bearer t" && req?.body == Data("{}".utf8))
            precondition(HTTPRequest.parse(raw.dropLast()) == nil)
            let sema = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var replies: [[String: Any]?] = []
            Task.detached {
                replies.append(await MCPHandler.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]], store: store))
                replies.append(await MCPHandler.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], store: store))
                replies.append(await MCPHandler.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                        "params": ["name": "list_meetings", "arguments": ["person": "Anna"]]], store: store))
                replies.append(await MCPHandler.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], store: store))
                replies.append(await MCPHandler.handle(["jsonrpc": "2.0", "id": 4, "method": "nope"], store: store))
                sema.signal()
            }
            sema.wait()
            precondition(((replies[0]?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "MeetNotes")
            precondition(((replies[1]?["result"] as? [String: Any])?["tools"] as? [Any])?.count == 5)
            let callText = (((replies[2]?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            precondition(callText.contains(m.id))
            precondition(replies[3] == nil && replies[4]?["error"] != nil)
        } catch { preconditionFailure("db selftest: \(error)") }
        // MCP task mapping: draft → typed tool arguments, ID lookups, pick-list parsing.
        let schema = #"{"properties":{"title":{"type":"string"},"description":{"type":"string"},"due_date":{"type":"string"},"board_id":{"type":"integer"},"asap":{"type":"boolean"},"tags":{"type":"array"}},"required":["title","board_id"]}"#
        let tool = MCPTool(name: "kaiten_create_card", description: "", schemaJSON: Data(schema.utf8))
        let listing = ["kaiten_list_boards", "kaiten_list_users", "kaiten_list_types"].map { MCPTool(name: $0, description: "", schemaJSON: Data("{}".utf8)) }
        precondition(TaskMapping.suggestTaskTool(listing + [tool]) == "kaiten_create_card")
        let args = TaskMapping.arguments(for: .init(title: "Fix", details: "Body", due: .now), tool: tool,
                                         shared: ["board_id": "42", "asap": "true", "tags": "a, b", "unknown": "x"])
        precondition(args["title"] as? String == "Fix" && args["description"] as? String == "Body" && args["board_id"] as? Int == 42)
        precondition(args["asap"] as? Bool == true && args["tags"] as? [String] == ["a", "b"] && args["unknown"] == nil && args["due_date"] is String)
        precondition(TaskMapping.lookupTool(for: "board_id", in: listing)?.name == "kaiten_list_boards")
        precondition(TaskMapping.lookupTool(for: "owner_id", in: listing)?.name == "kaiten_list_users")
        precondition(TaskMapping.lookupTool(for: "title", in: listing) == nil)
        precondition(TaskMapping.options(from: #"Boards: [{"id": 7, "title": "Dev"}, {"id": 8, "name": "Ops"}]"#).map(\.0) == ["7", "8"])
        precondition(TaskMapping.options(from: "• Dev board (id: 7)\n• Ops (id: 8)").map(\.1) == ["Dev board", "Ops"])
        precondition(TaskMapping.link(in: "Created card https://x.kaiten.ru/space/1/card/9.") == "https://x.kaiten.ru/space/1/card/9")
        print("selftest ok")
    }
}
