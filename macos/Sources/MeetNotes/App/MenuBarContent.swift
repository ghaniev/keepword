import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.recordingID == nil ? "Start Recording" : "Stop Recording (\(timestamp(model.currentElapsed)))") { model.toggleRecording() }
        if model.recordingID != nil {
            Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
            Button("Add Bookmark") { model.addBookmark() }
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
        Button("Open MeetNotes") { openWindow(id: "main"); NSApp.activate() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
