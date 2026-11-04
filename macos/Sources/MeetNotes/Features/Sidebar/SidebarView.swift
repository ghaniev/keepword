import SwiftUI
import UniformTypeIdentifiers

struct FolderNode: Identifiable, Hashable {
    let folder: Folder
    var children: [FolderNode]?
    var id: String { folder.id }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var folders: [Folder] = []
    @State private var counts: (all: Int, unsorted: Int, deleted: Int, byFolder: [String: Int]) = (0, 0, 0, [:])
    @State private var editing: Folder?

    private var selection: Binding<AppModel.Section?> {
        Binding(get: { model.section }, set: { if let s = $0 { model.section = s; model.searchText = "" } })
    }

    private func tree(parent: String?) -> [FolderNode] {
        folders.filter { $0.parentId == parent }.map { f in
            let kids = tree(parent: f.id)
            return FolderNode(folder: f, children: kids.isEmpty ? nil : kids)
        }
    }

    var body: some View {
        List(selection: selection) {
            Section {
                nav("Home", "house", .home)
                Label { HStack { Text("Chat"); BetaBadge() } } icon: { Image(systemName: "bubble.left.and.text.bubble.right") }
                    .tag(AppModel.Section.chat)
                nav("Calendar", "calendar", .calendar)
                nav("Action Items", "checkmark.circle", .actionItems)
                nav("People", "person.2", .people)
                nav("Tags", "tag", .tags)
            }
            Section {
                row("All Notes", icon: "tray.full", count: counts.all, .documents(.all))
                row("Unsorted", icon: "tray", count: counts.unsorted, .documents(.unsorted))
                OutlineGroup(tree(parent: nil), children: \.children) { node in
                    folderRow(node.folder)
                }
            } header: {
                HStack {
                    Text("FOLDERS")
                    Spacer()
                    Button { editing = Folder(id: UUID().uuidString, name: "", icon: "folder", color: "blue") } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain).help("New Folder")
                }
            }
            Section {
                row("Recently Deleted", icon: "trash", count: counts.deleted, .documents(.deleted))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { RecordControls().padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6) }
        .task(id: model.revision) {
            folders = (try? model.store.folders()) ?? []
            counts = (try? model.store.counts()) ?? counts
        }
        .sheet(item: $editing) { FolderEditSheet(folder: $0, folders: folders) }
    }

    private func nav(_ title: LocalizedStringKey, _ icon: String, _ s: AppModel.Section) -> some View {
        Label(title, systemImage: icon).tag(s)
    }

    private func row(_ title: LocalizedStringKey, icon: String, count: Int, _ s: AppModel.Section) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .tag(s)
    }

    private func folderRow(_ f: Folder) -> some View {
        HStack {
            Label { Text(f.name) } icon: { FolderIcon(icon: f.icon, color: f.color) }
            Spacer()
            Text("\(counts.byFolder[f.id] ?? 0)").font(.caption).foregroundStyle(.secondary)
        }
        .tag(AppModel.Section.documents(.folder(f.id)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { try? model.store.move(id, to: f.id) }
            return true
        }
        .contextMenu {
            Button("Edit Folder…") { editing = f }
            Button("New Subfolder…") { editing = Folder(id: UUID().uuidString, name: "", icon: "folder", color: f.color, parentId: f.id) }
            Divider()
            Button("Delete Folder", role: .destructive) {
                try? model.store.deleteFolder(f.id)
                if model.section == .documents(.folder(f.id)) { model.section = .documents(.all) }
            }
        }
    }
}

struct FolderEditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var folder: Folder
    let folders: [Folder]
    @State private var templates: [Template] = []
    private let icons = ["folder", "briefcase", "person.2", "person.crop.circle", "building.2", "hammer", "wrench.and.screwdriver",
                         "paintpalette", "chart.bar", "cart", "graduationcap", "heart", "star", "flag", "lightbulb", "calendar"]

    var body: some View {
        Form {
            TextField("Name", text: $folder.name)
            LabeledContent("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26)), count: 8), spacing: 6) {
                    ForEach(icons, id: \.self) { i in
                        Button { folder.icon = i } label: {
                            FolderIcon(icon: i, color: folder.color, size: 14).frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 5).fill(folder.icon == i ? Color.accentColor.opacity(0.2) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            TextField("…or an emoji", text: Binding(get: { icons.contains(folder.icon) ? "" : folder.icon },
                                                     set: { if let c = $0.last { folder.icon = String(c) } }))
            LabeledContent("Color") {
                HStack {
                    ForEach(Palette.keys, id: \.self) { k in
                        Circle().fill(Palette.color(k)).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary, lineWidth: folder.color == k ? 2 : 0))
                            .onTapGesture { folder.color = k }
                    }
                }
            }
            Picker("Parent", selection: $folder.parentId) {
                Text("None (top level)").tag(String?.none)
                ForEach(folders.filter { $0.id != folder.id }) { Text($0.name).tag(String?.some($0.id)) }
            }
            Picker("Summary template", selection: $folder.templateId) {
                Text("Use Default").tag(String?.none)
                ForEach(templates) { Text($0.name).tag(String?.some($0.id)) }
            }
            VStack(alignment: .leading) {
                Text("Shared context")
                TextEditor(text: $folder.context).font(.body).frame(height: 70)
                Text("Background the AI should know for every meeting in this folder (client, project, people).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { try? model.store.saveFolder(folder); dismiss() }.disabled(folder.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { templates = (try? model.store.templates()) ?? [] }
    }
}
