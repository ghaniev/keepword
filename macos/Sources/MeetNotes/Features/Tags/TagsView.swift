import SwiftUI

struct TagsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tags: [(Tag, Int)] = []
    @State private var renaming: Tag?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tags").font(.system(size: 17, weight: .semibold))
                CountBadge(count: tags.count)
                Spacer()
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            Divider()
            if tags.isEmpty {
                EmptyState(icon: "tag", title: "No tags yet", message: "Tags are added by AI summaries, or by hand on a document.")
            } else {
                ScrollView {
                    FlowLayout(spacing: 10) {
                        ForEach(tags, id: \.0.id) { t, count in
                            Button { model.section = .documents(.tag(t.id)) } label: {
                                HStack(spacing: 6) {
                                    Text("#\(t.name)")
                                    Text("\(count)").foregroundStyle(.secondary)
                                }
                                .font(.system(size: 13)).foregroundStyle(Palette.tagText)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tagFill))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit Tag…") { newName = t.name; renaming = t }
                                Button("Delete Tag", role: .destructive) { try? model.store.deleteTag(t.id) }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: model.revision) { tags = (try? model.store.allTags()) ?? [] }
        .alert("Edit Tag", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Tag name", text: $newName)
            Button("Save") { if let t = renaming, !newName.isEmpty { try? model.store.renameTag(t.id, newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
