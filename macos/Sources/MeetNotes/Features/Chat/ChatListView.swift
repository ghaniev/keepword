import SwiftUI

struct ChatSessionListColumn: View {
    @EnvironmentObject var model: AppModel
    @State private var sessions: [ChatSession] = []
    @State private var filter = ""
    @State private var renaming: ChatSession?
    @State private var newTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { model.selectedChat = nil } label: { Label("New Chat", systemImage: "plus.circle.fill").font(.system(size: 11.5)) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $filter).textFieldStyle(.plain)
            }
            .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 12).padding(.bottom, 8)
            LiveQueriesSection()
            Divider().padding(.horizontal, 12).padding(.bottom, 6)
            if sessions.isEmpty {
                EmptyState(icon: "bubble.left.and.text.bubble.right", title: "No chats yet", message: "Ask a question across all your meetings.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sessions.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }) { s in
                            Card(selected: model.selectedChat == s.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(s.updatedAt.formatted(.relative(presentation: .named))).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                            }
                            .onTapGesture { model.selectedChat = s.id }
                            .contextMenu {
                                Button("Rename Chat…") { newTitle = s.title; renaming = s }
                                Button("Delete Chat", role: .destructive) {
                                    try? model.store.deleteSession(s.id)
                                    if model.selectedChat == s.id { model.selectedChat = nil }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .background(Palette.cardFill)
        .task(id: model.revision) { sessions = (try? model.store.chatSessions(meetingID: nil)) ?? [] }
        .alert("Rename Chat", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Chat title", text: $newTitle)
            Button("Rename") { if var s = renaming { s.title = newTitle; try? model.store.saveSession(s) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct GlobalChatDetail: View {
    @EnvironmentObject var model: AppModel
    @State private var saving: SavedQuery?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text("Chat").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    let lastQuestion = model.selectedChat.flatMap { try? model.store.messages($0).last { $0.role == "user" }?.content } ?? ""
                    saving = SavedQuery(id: UUID().uuidString, name: String(lastQuestion.prefix(40)), prompt: lastQuestion)
                } label: { Label("Save as Live Query", systemImage: "clock.arrow.2.circlepath") }
                    .buttonStyle(.borderless).font(.caption).help("Pick a scope and save it as a live query")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            ChatPane(sessionID: $model.selectedChat, meetingID: nil)
        }
        .sheet(item: $saving) { SavedQueryEditor(query: $0) }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
