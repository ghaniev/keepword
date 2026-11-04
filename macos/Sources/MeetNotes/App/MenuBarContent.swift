import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.recordingID == nil ? "Start Recording" : "Stop Recording (\(timestamp(model.currentElapsed)))") { model.toggleRecording() }
        if model.recordingID != nil {
            Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
            Button("Add Bookmark") { model.addBookmark() }
        } else if UserDefaults.standard.string(forKey: "recordingMode") != RecordingMode.micOnly.rawValue {
            Button("Start In-Person Meeting") { model.startRecording(mode: .micOnly) }
                .help("Records the microphone only, for a meeting in the room")
        }
        Divider()
        let upcoming = model.calendar.upcoming.prefix(5)
        if !upcoming.isEmpty {
            Text("Upcoming Meetings")
            ForEach(Array(upcoming)) { e in
                Button("\(e.start.hhmm)  \(e.title)") {
                    if let url = e.videoLink { NSWorkspace.shared.open(url) }
                    model.startRecording(event: e)
                }
            }
            Divider()
        }
        if let last = model.store.latestMeeting() {
            Button("Open “\(last.title)”") { show { model.open(last.id) } }
        }
        Button("Ask Keepword…") { show { model.searchText = ""; model.section = .chat; model.selectedChat = nil } }
        Button("Open Keepword") { show {} }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show(_ navigate: () -> Void) {
        navigate()
        openWindow(id: "main")
        NSApp.activate()
    }
}
