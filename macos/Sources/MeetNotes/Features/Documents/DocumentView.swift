import SwiftUI

struct DocumentView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @State private var folder: Folder?
    @State private var templateName = ""
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if meeting.id == model.recordingID { PulsingDot() }
                    if let folder {
                        FolderIcon(icon: folder.icon, color: folder.color, size: 14)
                        Text("\(folder.name) /").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    TextField("Title", text: $title).textFieldStyle(.plain).font(.system(size: 21, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit { try? model.store.update(meeting.id) { $0.title = title }; titleFocused = false }
                    Spacer()
                    Menu { DocumentMenu(meeting: meeting) } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                HStack(spacing: 14) {
                    Label(meeting.createdAt.hhmm, systemImage: "calendar").fixedSize().help(meeting.createdAt.formatted(date: .complete, time: .shortened))
                    Label(durationLabel(meeting.duration), systemImage: "clock").fixedSize()
                    Menu {
                        Button("Unsorted") { try? model.store.move(meeting.id, to: nil) }
                        ForEach((try? model.store.folders()) ?? []) { f in Button(f.name) { try? model.store.move(meeting.id, to: f.id) } }
                    } label: {
                        Label(folder?.name ?? String(localized: "Unsorted"), systemImage: "folder").foregroundStyle(.orange)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    Menu {
                        Button("Use Folder / Default") { try? model.store.update(meeting.id) { $0.templateId = nil } }
                        ForEach((try? model.store.templates()) ?? []) { t in Button(t.name) { try? model.store.update(meeting.id) { $0.templateId = t.id } } }
                    } label: { Label(templateName, systemImage: "doc.text") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Change template")
                    Spacer()
                    if let mod = meeting.modifiedAt {
                        Text("Modified \(mod.formatted(date: .numeric, time: .shortened))").foregroundStyle(.tertiary).layoutPriority(-1)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                TextTabs(tabs: [(DocumentTab.summary, "Summary"), (.transcript, "Transcript"), (.chat, "Chat")], selection: $model.documentTab)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
            .readableColumn()
            switch model.documentTab {
            case .summary: SummaryTab(meeting: meeting)
            case .transcript: TranscriptTab(meeting: meeting, player: model.player)
            case .chat: DocumentChatView(meetingID: meeting.id)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { title = meeting.title }
        .onChange(of: meeting.title) { title = $1 }
        .task(id: model.revision) {
            folder = meeting.folderId.flatMap { id in (try? model.store.folders())?.first { $0.id == id } }
            let t = try? model.store.template(for: meeting)
            templateName = meeting.templateId == nil ? String(localized: "\(t?.name ?? String(localized: "Default")) Template") : (t?.name ?? String(localized: "Template"))
        }
    }
}
