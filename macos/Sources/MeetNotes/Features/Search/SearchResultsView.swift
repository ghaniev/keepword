import SwiftUI

struct SearchResultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var results: [Pipeline.SearchResult] = []
    @State private var searching = false
    @State private var saving: SavedQuery?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search Results").font(.system(size: 17, weight: .semibold))
                    Text(searching ? "Searching meetings…" : "\(plural(results.count, "result")) for “\(model.searchText)”").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { saving = SavedQuery(id: UUID().uuidString, name: model.searchText, prompt: "Summarize what was said about \(model.searchText).") } label: {
                    Label("Save as Live Query", systemImage: "clock.arrow.2.circlepath")
                }
                .help("Save this search as a live query")
                Button {
                    let q = model.searchText
                    model.searchText = ""
                    model.section = .chat
                    model.selectedChat = nil
                    model.pendingChatPrompt = q
                } label: { Label("Ask AI", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(.borderedProminent).tint(Color.accentColor.opacity(0.85)).help("Ask AI about these search results")
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            if !searching && results.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "No matching meetings", message: "Try a different search term")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(results) { r in
                            Button { model.open(r.meeting.id, at: r.snippetTime) } label: { SearchResultCard(result: r, query: model.searchText) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 20).frame(maxWidth: 900)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: $saving) { SavedQueryEditor(query: $0) }
        .task(id: model.searchText) {
            try? await Task.sleep(for: .milliseconds(250))  // debounce typing
            guard !Task.isCancelled else { return }
            searching = true
            results = (try? await Pipeline.search(model.searchText, store: model.store)) ?? []
            searching = false
        }
    }
}

struct SearchResultCard: View {
    let result: Pipeline.SearchResult
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.meeting.title).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 10) {
                        Label(result.meeting.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        Label(durationLabel(result.meeting.duration), systemImage: "clock")
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(Int(result.score * 100))%", systemImage: "star.fill").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.13)))
            }
            Divider()
            Text(highlighted).font(.system(size: 12.5)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }

    /// Yellow highlight on the query words.
    private var highlighted: AttributedString {
        var s = AttributedString(result.snippet)
        for word in query.split(separator: " ").map(String.init) where word.count > 1 {
            var start = s.startIndex
            while let r = s[start...].range(of: word, options: .caseInsensitive) {
                s[r].backgroundColor = Color.yellow.opacity(0.45)
                s[r].font = .system(size: 12.5, weight: .semibold)
                start = r.upperBound
            }
        }
        return s
    }
}
