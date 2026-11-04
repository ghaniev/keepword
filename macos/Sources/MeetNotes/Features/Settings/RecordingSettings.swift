import SwiftUI

struct RecordingSettings: View {
    @AppStorage("recordingMode") private var mode = RecordingMode.both.rawValue
    @AppStorage("inputDeviceUID") private var inputUID = ""
    @AppStorage("liveTranscription") private var live = true
    @State private var devices = AudioDevices.inputs()

    var body: some View {
        Form {
            Section("Recording Mode") {
                Picker("Default Recording Mode", selection: $mode) {
                    ForEach(RecordingMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("System audio captures the other participants without a bot. macOS asks once for “System Audio Recording” permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Input Device", selection: $inputUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                Button("Refresh") { devices = AudioDevices.inputs() }
            }
            Section("Real-Time Transcription") {
                Toggle("Enable live transcription while recording", isOn: $live)
                Text("Live text is a preview; the final transcript with speakers is produced after the call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                LabeledContent("Start / stop recording", value: "⌘R")
                LabeledContent("Add bookmark", value: "⌘B")
                LabeledContent("Import audio/video", value: "⌘I")
            }
        }
        .formStyle(.grouped)
    }
}
