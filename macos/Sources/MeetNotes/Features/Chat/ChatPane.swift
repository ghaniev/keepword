import SwiftUI

struct DocumentChatView: View {
    @EnvironmentObject var model: AppModel
    let meetingID: String
    @State private var sessionID: String?
    @State private var sessions: [ChatSession] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if sessions.count > 1 {
                    Menu {
                        ForEach(sessions) { s in Button(s.title) { sessionID = s.id } }
                    } label: { Label("Sessions", systemImage: "clock.arrow.circlepath") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Button { sessionID = nil } label: { Label("New Chat", systemImage: "plus") }.buttonStyle(.borderless)
            }
            .font(.system(size: 11.5)).padding(.horizontal, 22).padding(.bottom, 4)
            Divider()
            ChatPane(sessionID: $sessionID, meetingID: meetingID)
        }
        .task(id: model.revision) {
            sessions = (try? model.store.chatSessions(meetingID: meetingID)) ?? []
            if !loaded { sessionID = sessions.first?.id; loaded = true }
        }
    }
}

struct ChatPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var sessionID: String?
    let meetingID: String?
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var suggestions: [(String, String)] = []  // (label, insertion)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if messages.isEmpty && !thinking {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Start a Conversation").font(.headline)
                                Text(meetingID == nil
                                     ? "Ask across all meetings. Use @Name for a person, @tag for a tag, or @'Title' for a meeting."
                                     : "Ask about this meeting: “What were the decisions?”, “Summarize the last 10 minutes”, “What did @Name say about the budget?”")
                                    .foregroundStyle(.secondary).font(.callout)
                                FlowLayout {
                                    ForEach(starters, id: \.self) { s in
                                        Button(s) { draft = s; send() }.buttonStyle(.bordered).controlSize(.small)
                                    }
                                }
                            }
                            .padding(.top, 20)
                        }
                        ForEach(messages) { m in MessageView(message: m) }
                        if thinking {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .readableColumn()
                }
                .onChange(of: messages.count) { withAnimation { proxy.scrollTo("end") } }
                .onChange(of: thinking) { withAnimation { proxy.scrollTo("end") } }
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(suggestions, id: \.0) { label, insertion in
                            Button(label) { complete(insertion) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .padding(.vertical, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(meetingID == nil ? "Ask about all meetings… (@ to mention)" : "Ask about this meeting… (@ to mention)",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6).focused($focused)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.plain).foregroundStyle(draft.isEmpty || thinking ? Color.secondary : Color.accentColor)
                    .disabled(draft.isEmpty || thinking)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
            .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 4)
            .readableColumn()
        }
        .task(id: "\(model.revision)-\(sessionID ?? "")") {
            messages = sessionID.flatMap { try? model.store.messages($0) } ?? []
        }
        .onChange(of: draft) { _, new in updateSuggestions(new) }
        .onAppear {
            if let p = model.pendingChatPrompt { model.pendingChatPrompt = nil; draft = p; send() }
            focused = true
        }
    }

    private var starters: [String] {
        meetingID == nil
            ? [String(localized: "What decisions were made this week?"), String(localized: "List all follow-ups assigned to me"),
               String(localized: "What are the recurring themes?")]
            : [String(localized: "Summarize this meeting"), String(localized: "List all follow-ups"),
               String(localized: "What questions were left open?"), String(localized: "What was discussed at the end?")]
    }

    private func updateSuggestions(_ text: String) {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else {
            suggestions = []; return
        }
        let q = last.dropFirst().lowercased()
        var out: [(String, String)] = []
        for (p, _) in (try? model.store.people()) ?? [] where q.isEmpty || p.name.lowercased().hasPrefix(q) {
            out.append(("👤 " + p.name, "@" + (p.name.split(separator: " ").first.map(String.init) ?? p.name)))
        }
        for (t, _) in (try? model.store.allTags()) ?? [] where q.isEmpty || t.name.hasPrefix(q) { out.append(("# " + t.name, "@" + t.name)) }
        if meetingID == nil {
            for m in (try? model.store.meetings(.all))?.prefix(50) ?? [] where q.count >= 2 && m.title.lowercased().contains(q) {
                out.append(("📄 " + m.title, "@'\(m.title)'"))
            }
        }
        suggestions = Array(out.prefix(12))
    }

    private func complete(_ insertion: String) {
        var parts = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty { parts[parts.count - 1] = insertion + " " }
        draft = parts.joined(separator: " ")
        suggestions = []
        focused = true
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thinking else { return }
        draft = ""
        suggestions = []
        Task {
            do {
                let session: ChatSession
                if let id = sessionID, let s = try model.store.chatSessions(meetingID: meetingID).first(where: { $0.id == id }) {
                    session = s
                } else {
                    session = ChatSession(id: UUID().uuidString, meetingId: meetingID, title: String(question.prefix(48)), createdAt: .now, updatedAt: .now)
                    try model.store.saveSession(session)
                    sessionID = session.id
                }
                let history = try model.store.messages(session.id)
                try model.store.append(ChatMessage(sessionId: session.id, role: "user", content: question))
                thinking = true
                defer { thinking = false }
                let (reply, citations) = try await Pipeline.answer(question, session: session, history: history, store: model.store)
                try model.store.append(ChatMessage(sessionId: session.id, role: "assistant", content: reply, citations: citations))
            } catch {
                if let id = sessionID {
                    try? model.store.append(ChatMessage(sessionId: id, role: "assistant", content: "⚠️ \(error.localizedDescription)"))
                }
            }
        }
    }
}

struct MessageView: View {
    @EnvironmentObject var model: AppModel
    let message: ChatMessage
    @State private var showSources = false

    /// Only citations the answer actually references, keyed by their number.
    private var used: [(Int, Citation)] {
        let nums = Set(message.content.matches(of: #/\[(\d+)\]/#).compactMap { Int($0.1) })
        return message.citations.enumerated().map { ($0.offset + 1, $0.element) }.filter { nums.contains($0.0) }
    }

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 80)
                Text(message.content).font(.system(size: 13)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // [n] → link that jumps to the cited moment.
                MarkdownText(text: message.content.replacing(#/\[(\d+)\]/#) { "[\\[\($0.1)\\]](meetnotes://cite/\($0.1))" }) { url in
                    if let n = Int(url.lastPathComponent), n >= 1, n <= message.citations.count {
                        let c = message.citations[n - 1]
                        model.open(c.meetingId, at: c.start)
                    }
                }
                if !used.isEmpty {
                    DisclosureGroup(isExpanded: $showSources) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(used, id: \.0) { n, c in
                                Button { model.open(c.meetingId, at: c.start) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("[\(n)]").foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("\(c.title) · \(timestamp(c.start))–\(timestamp(c.end))").font(.caption).foregroundStyle(.secondary)
                                            Text(c.text).font(.caption).lineLimit(2)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    } label: { Text("\(used.count) sources").font(.caption).foregroundStyle(.secondary) }
                }
                Text(message.createdAt.hhmm).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
