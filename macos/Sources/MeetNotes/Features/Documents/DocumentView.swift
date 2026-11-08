import SwiftUI

struct DocumentView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @State private var folder: Folder?
    @State private var peopleCount = 0
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if meeting.id == model.recordingID { PulsingDot() }
                    TextField("Title", text: $title).textFieldStyle(.plain).font(.system(size: 24, weight: .bold))
                        .focused($titleFocused)
                        .onSubmit { try? model.store.update(meeting.id) { $0.title = title }; titleFocused = false }
                    Spacer()
                    Menu {
                        DocumentMenu(meeting: meeting)
                        if let mod = meeting.modifiedAt {
                            Divider()
                            Text("Modified \(mod.formatted(date: .numeric, time: .shortened))")
                        }
                    } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                // "Tue 4 Nov, 20:29 · 23 min · 6 people · Product"
                HStack(spacing: 6) {
                    Text(meeting.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                        .help(meeting.createdAt.formatted(date: .complete, time: .shortened))
                    Text("·")
                    Text(minutesLabel(meeting.duration))
                    if peopleCount > 0 { Text("·"); Text(peopleCount == 1 ? String(localized: "1 person") : String(localized: "\(peopleCount) people")) }
                    Text("·")
                    Menu {
                        Button("Inbox") { try? model.store.move(meeting.id, to: nil) }
                        ForEach((try? model.store.folders()) ?? []) { f in Button(f.name) { try? model.store.move(meeting.id, to: f.id) } }
                    } label: {
                        HStack(spacing: 4) {
                            if let folder { FolderIcon(icon: folder.icon, color: folder.color, size: 11) } else { Image(systemName: "tray") }
                            Text(folder?.name ?? String(localized: "Inbox"))
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Move to folder")
                    Spacer()
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                TextTabs(tabs: [(DocumentTab.summary, "Recap"), (.transcript, "Transcript"), (.chat, "Ask")], selection: $model.documentTab)
                    .padding(.top, 8)
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
            peopleCount = (try? model.store.participants(of: meeting.id).count) ?? 0
        }
    }
}
