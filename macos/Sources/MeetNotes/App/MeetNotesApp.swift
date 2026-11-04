import SwiftUI

@main
struct MeetNotesApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    init() {
        DevCommands.runIfRequested()
    }

    var body: some Scene {
        Window("MeetNotes", id: "main") {
            RootView().environmentObject(model).frame(minWidth: 1000, minHeight: 620)
                .onOpenURL { model.handle($0) }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultLaunchBehavior(.presented)  // always open the main window at launch, even if it was closed last time
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.recordingID == nil ? "Start Recording" : "Stop Recording") { model.toggleRecording() }
                    .keyboardShortcut("r")
                Button("Add Bookmark") { model.addBookmark() }.keyboardShortcut("b").disabled(model.recordingID == nil)
                Button("Capture Screenshot") { model.takeScreenshot(area: false) }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.recordingID == nil)
                Button("Capture Selected Area…") { model.takeScreenshot(area: true) }.keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.recordingID == nil)
                Button("Show Meeting Overlay") { MeetingOverlay.shared.show(model) }.disabled(model.recordingID == nil)
                Button("Import Audio/Video…") { model.importWithPanel() }.keyboardShortcut("i")
                Button("Set Up AI…") { model.showWelcome = true }
            }
            CommandGroup(after: .appSettings) { PermissionsMenuButton() }
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.focusSearch.toggle() }.keyboardShortcut("f")
            }
        }
        Settings { SettingsView().environmentObject(model) }
        Window("Permissions", id: "permissions") { PermissionsView().environmentObject(model) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)  // opened by RootView when needed, never restored by itself
            .restorationBehavior(.disabled)
        MenuBarExtra("MeetNotes", systemImage: model.recordingID == nil ? "waveform" : "record.circle.fill", isInserted: $showMenuBarIcon) {
            MenuBarContent().environmentObject(model)
        }
    }
}

/// MeetNotes → Permissions… in the app menu.
private struct PermissionsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Permissions…") { openWindow(id: "permissions") } }
}
