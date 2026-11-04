import SwiftUI

/// "Re-identify Speakers…": runs transcription and diarization again with an exact number of voices,
/// which keeps similar voices apart better than guessing the count.
struct SpeakerCountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meetingID: String
    @State private var count = 0  // 0 = automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Re-identify Speakers").font(.title3.weight(.semibold))
            Text("How many voices to separate? For a recorded call, count the other participants without you; for an imported file, count everyone. Transcription runs again, and manual edits to the transcript are replaced.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Voices", selection: $count) {
                Text("Automatic").tag(0)
                ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
            }
            .fixedSize()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Re-identify") {
                    try? model.store.update(meetingID) { $0.expectedSpeakers = count == 0 ? nil : count }
                    try? model.store.setStatus(meetingID, "queued")
                    model.enqueue(meetingID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460)
        .onAppear { count = model.store.meeting(meetingID)?.expectedSpeakers ?? 0 }
    }
}
