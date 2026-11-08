import SwiftUI

struct TranscriptTab: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @ObservedObject var player: AudioPlayer
    @State private var segments: [Segment] = []
    @State private var speakers: [String: Speaker] = [:]
    @State private var people: [(Speaker, Int)] = []
    @State private var bookmarks: [Bookmark] = []
    @State private var screenshots: [Attachment] = []
    @State private var speakerFilter: String?
    @State private var query = ""
    @State private var showOriginal = false
    @State private var editing: Segment?
    @State private var editText = ""
    @State private var splitting: Segment?
    @State private var renaming: Speaker?
    @State private var newName = ""
    @State private var newPersonFor: Segment?

    private var visible: [Segment] {
        segments.filter { s in
            !s.irrelevant
                && (speakerFilter == nil || model.store.root(s.speakerId, in: speakers)?.id == speakerFilter)
                && (query.isEmpty || s.text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if meeting.id == model.recordingID {
                LiveTranscriptView(live: model.live)
            } else {
                AudioPlayerBar(player: model.player, meeting: meeting, bookmarks: bookmarks).padding(.horizontal, 22).padding(.bottom, 8)
                    .readableColumn()
                HStack(spacing: 10) {
                    Menu {
                        Button("All Speakers") { speakerFilter = nil }
                        Divider()
                        ForEach(uniqueSpeakers, id: \.id) { s in Button(s.name) { speakerFilter = s.id } }
                    } label: {
                        Label(speakerFilter.flatMap { speakers[$0]?.name } ?? String(localized: "All Speakers"), systemImage: "person.2")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search transcript", text: $query).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).frame(width: 200)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    if !query.isEmpty { Text("\(visible.count) matches").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Menu {
                        Toggle("Show Original Text", isOn: $showOriginal)
                        Button("Copy Transcript") {
                            copyToPasteboard(visible.map { "[\(timestamp($0.start))] \(name($0)): \($0.text)" }.joined(separator: "\n"))
                        }
                        Button("Clean Up Transcript") { model.cleanUp(meeting.id) }
                        Button("Identify Speakers…") { model.identifyingSpeakers = meeting.id }
                        Button("Identify Speakers Again") { try? model.store.setStatus(meeting.id, "queued"); model.enqueue(meeting.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .font(.system(size: 12)).padding(.horizontal, 22).padding(.bottom, 6)
                .readableColumn()
                Divider()
                if segments.isEmpty {
                    EmptyState(icon: "text.quote", title: meeting.isProcessing || meeting.status == "queued" ? "\(meeting.statusLabel)" : "No transcript available",
                               message: "Transcript will appear here when complete.")
                } else {
                    blocks
                }
            }
        }
        .task(id: model.revision) {
            segments = (try? model.store.segments(of: meeting.id)) ?? []
            speakers = (try? model.store.speakers()) ?? [:]
            people = (try? model.store.people()) ?? []
            bookmarks = (try? model.store.bookmarks(of: meeting.id)) ?? []
            screenshots = ((try? model.store.attachments(of: meeting.id)) ?? []).filter { $0.isImage && $0.recordingTime != nil }
        }
        .sheet(item: $editing) { s in
            TextEditSheet(title: "Edit Text", text: $editText) { try? model.store.editSegment(s.id!, text: editText) }
        }
        .sheet(item: $splitting) { s in SplitSheet(segment: s) }
        .alert("Rename Speaker in All Meetings", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if var s = renaming, !newName.isEmpty { s.name = newName; try? model.store.saveSpeaker(s) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The voice is remembered: future meetings will use this name.") }
        .alert("New Person", isPresented: .init(get: { newPersonFor != nil }, set: { if !$0 { newPersonFor = nil } })) {
            TextField("Person name", text: $newName)
            Button("Assign") {
                if let seg = newPersonFor, !newName.isEmpty, let p = try? model.store.newPerson(named: newName) {
                    try? model.store.assign(segment: seg.id!, to: p.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var uniqueSpeakers: [Speaker] {
        var seen = Set<String>()
        return segments.compactMap { model.store.root($0.speakerId, in: speakers) }.filter { seen.insert($0.id).inserted }
    }

    private func name(_ s: Segment) -> String { model.store.root(s.speakerId, in: speakers)?.name ?? String(localized: "Unknown") }

    private var blocks: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { i, s in
                        let playing = player.meetingID == meeting.id && player.isPlaying
                            && player.currentTime >= s.start && player.currentTime < s.end
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Button(timestamp(s.start)) { model.player.load(meeting); model.player.play(from: s.start) }
                                    .buttonStyle(.plain).monospacedDigit()
                                Text("·")
                                Text(name(s)).fontWeight(.medium)
                                if s.overlap {
                                    Image(systemName: "person.2.wave.2")
                                        .help("People talk at the same time here; some words may belong to another speaker")
                                }
                                if s.originalText != nil && !s.userEdited { Image(systemName: "sparkles").help("Cleaned by AI") }
                                if s.userEdited { Text("Edited").foregroundStyle(.tertiary) }
                            }
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(showOriginal ? (s.originalText ?? s.text) : s.text)
                                .font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(playing ? Color.accentColor.opacity(0.08) : .clear))
                        .id(s.id)
                        .contextMenu { blockMenu(s) }
                        ForEach(shots(after: i)) { TranscriptScreenshot(attachment: $0) { model.player.load(meeting); model.player.play(from: $0) } }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .readableColumn()
            }
            .onChange(of: model.transcriptJump?.time) { _, _ in jump(proxy) }
            .onAppear { jump(proxy) }
        }
    }

    /// Screenshots taken between this block and the next one (the first block also takes earlier ones).
    private func shots(after i: Int) -> [Attachment] {
        let v = visible
        let lo = i == 0 ? -Double.infinity : v[i].start
        let hi = i + 1 < v.count ? v[i + 1].start : Double.infinity
        return screenshots.filter { ($0.recordingTime ?? 0) >= lo && ($0.recordingTime ?? 0) < hi }
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let j = model.transcriptJump, j.meeting == meeting.id else { return }
        let target = segments.last { $0.start <= j.time + 0.5 } ?? segments.first
        withAnimation { proxy.scrollTo(target?.id, anchor: .center) }
        model.player.load(meeting)
        model.player.play(from: j.time)
        model.transcriptJump = nil
    }

    @ViewBuilder private func blockMenu(_ s: Segment) -> some View {
        Button("Play from this timestamp") { model.player.load(meeting); model.player.play(from: s.start) }
        Button("Edit Text…") { editText = s.text; editing = s }
        Menu("Assign Person") {
            ForEach(people, id: \.0.id) { p, _ in Button(p.name) { try? model.store.assign(segment: s.id!, to: p.id) } }
            Divider()
            Button("New Person…") { newName = ""; newPersonFor = s }
        }
        if let sp = model.store.root(s.speakerId, in: speakers) {
            Button("Rename “\(sp.name)”…") { newName = sp.name; renaming = sp }
        }
        Button("Split Block…") { splitting = s }
        if s.originalText != nil { Button("Restore Original Text") { try? model.store.restoreOriginal(s.id!) } }
        Button("Add Bookmark Here") { try? model.store.addBookmark(meeting.id, at: s.start) }
        Button("Ask About This Moment") {
            model.documentTab = .chat
            model.pendingChatPrompt = "What was being discussed around \(timestamp(s.start))?"
        }
    }
}

struct SplitSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let segment: Segment
    @State private var position: Double = 0.5

    private var words: [Substring] { segment.text.split(separator: " ") }
    private var cut: Int { max(1, min(words.count - 1, Int(Double(words.count) * position))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Split Transcription Block").font(.headline)
            Slider(value: $position, in: 0...1)
            Text(words[..<cut].joined(separator: " ")).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
            Text(words[cut...].joined(separator: " ")).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Split") {
                    try? model.store.split(segment: segment, at: words[..<cut].joined(separator: " ").count)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(words.count < 2)
            }
        }
        .padding().frame(width: 480)
    }
}
