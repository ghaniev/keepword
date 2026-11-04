import SwiftUI

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showMenuBarIcon") private var menuBar = true
    @AppStorage("meetingOverlay") private var overlay = true
    @AppStorage("callDetection") private var callDetection = true
    @AppStorage("autoStopPrompt") private var autoStop = true
    @AppStorage("autoSummarize") private var autoSummarize = true
    @AppStorage("deleteAudioAfterProcessing") private var deleteAudio = false
    @State private var ignored = UserDefaults.standard.stringArray(forKey: "ignoredCallApps") ?? []
    /// App-only language override ("" = follow macOS), applied on the next launch.
    @State private var language = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first ?? ""
    @State private var languageChanged = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Microphone, system audio, screen, calendars, reminders") {
                    Button("Permissions…") { openWindow(id: "permissions") }
                }
            }
            Section("Language") {
                Picker("App language", selection: $language) {
                    Text("System").tag("")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
                .onChange(of: language) { _, v in
                    if v.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                    else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("Restart MeetNotes to apply.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") {
                            let config = NSWorkspace.OpenConfiguration()
                            config.createsNewApplicationInstance = true
                            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                                DispatchQueue.main.async { NSApp.terminate(nil) }
                            }
                        }
                    }
                }
            }
            Section("Menu Bar & Dock") {
                Toggle("Show menu bar icon", isOn: $menuBar)
                Toggle("Show meeting overlay while recording", isOn: $overlay)
            }
            Section("Call Start/Stop Detection") {
                Toggle("Offer to record when a call starts (Zoom, Teams, Meet, Slack…)", isOn: $callDetection)
                    .onChange(of: callDetection) { _, on in on ? model.callDetector.start() : model.callDetector.stop() }
                Toggle("Ask to stop when the call ends", isOn: $autoStop)
                if !ignored.isEmpty {
                    LabeledContent("Ignored Apps") {
                        VStack(alignment: .trailing) {
                            ForEach(ignored, id: \.self) { b in
                                HStack {
                                    Text(CallDetector.conferencing[b] ?? b)
                                    Button("Remove") {
                                        ignored.removeAll { $0 == b }
                                        UserDefaults.standard.set(ignored, forKey: "ignoredCallApps")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section("Processing") {
                Toggle("Auto-generate summaries after transcription", isOn: $autoSummarize)
                Toggle("Delete audio files after processing", isOn: $deleteAudio)
            }
            Section("Storage") {
                LabeledContent("Library", value: Store.dataDir.path)
                Button("Show in Finder") { NSWorkspace.shared.open(Store.dataDir) }
            }
        }
        .formStyle(.grouped)
    }
}
