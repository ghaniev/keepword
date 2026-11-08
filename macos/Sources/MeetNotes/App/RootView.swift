import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
        } detail: {
            MainArea()
        }
        .toolbar {
            ToolbarItem(placement: .principal) { SearchField() }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).shadow(radius: 6).padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.default, value: model.toast)
        .tint(Palette.brand)
        .task {
            // Without the microphone or system audio nothing can be recorded: ask up front.
            if UserDefaults.standard.flag("permissionsAtLaunch", true), !CommandLine.arguments.contains("--demo"), Permission.missingRequired {
                openWindow(id: "permissions")
            }
        }
        .onChange(of: model.permissionsRequested) { _, asked in
            guard asked else { return }
            openWindow(id: "permissions")
            model.permissionsRequested = false
        }
        .sheet(isPresented: $model.showWelcome) { WelcomeView() }
        .sheet(item: Binding(get: { model.identifyingSpeakers.map(IDBox.init) }, set: { model.identifyingSpeakers = $0?.id })) {
            SpeakerWizard(meetingID: $0.id)
        }
        .sheet(item: Binding(get: { model.respeaking.map(IDBox.init) }, set: { model.respeaking = $0?.id })) {
            SpeakerCountSheet(meetingID: $0.id)
        }
        .sheet(item: $model.taskRequest) { CreateTaskSheet(mcp: model.mcpClients, request: $0) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.importFile(url) } }
                }
            }
            return true
        }
    }
}

/// The area right of the sidebar. Documents, chat, people and tags get a list column + detail;
/// home, calendar, action items and search results use the full width.
/// Detail panes declare a small ideal width: HSplitView sizes a pane to its content's ideal width,
/// and the 860pt reading column would otherwise push the layout past a narrow window's edges.
struct MainArea: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView()
        } else {
            switch model.section {
            case .home: HomeView(calendar: model.calendar)
            case .calendar: CalendarWeekView(calendar: model.calendar)
            case .actionItems: AllActionItemsView()
            case .chat:
                HSplitView {
                    ChatSessionListColumn().frame(minWidth: 230, idealWidth: 270, maxWidth: 380)
                    GlobalChatDetail().frame(minWidth: 420, idealWidth: 420)
                }
            case .people:
                HSplitView {
                    PeopleListColumn().frame(minWidth: 230, idealWidth: 270, maxWidth: 380)
                    PersonDetailView().frame(minWidth: 420, idealWidth: 420)
                }
            case .tags:
                TagsView()
            case .documents(let scope):
                HSplitView {
                    DocumentListColumn(scope: scope).frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
                    Group {
                        if scope == .deleted {
                            RecentlyDeletedDetail()
                        } else if let id = model.selectedMeeting, let m = model.store.meeting(id) {
                            DocumentView(meeting: m).id(id)
                        } else {
                            EmptyState(icon: "waveform", title: "No meeting selected", message: "Press ⌘R to record a call, or drop an audio/video file here.")
                        }
                    }
                    .frame(minWidth: 460, idealWidth: 460)
                }
            }
        }
    }
}

struct IDBox: Identifiable { let id: String }
