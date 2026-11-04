import SwiftUI

struct AudioPlayerBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: AudioPlayer
    let meeting: Meeting
    let bookmarks: [Bookmark]
    @State private var confirmDelete = false

    var body: some View {
        let current = player.meetingID == meeting.id
        HStack(spacing: 10) {
            Button {
                if !current { player.load(meeting) }
                player.toggle()
            } label: {
                Image(systemName: current && player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.plain).disabled(!FileManager.default.fileExists(atPath: meeting.folder.path))
            GeometryReader { geo in
                let total = max(current ? player.duration : meeting.duration, 1)
                let progress = current ? player.currentTime / total : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * progress, height: 4)
                    ForEach(bookmarks) { b in
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                            .offset(x: geo.size.width * b.time / total - 4)
                            .help("Bookmark \(timestamp(b.time))")
                            .onTapGesture { if !current { player.load(meeting) }; player.play(from: b.time) }
                    }
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10).offset(x: geo.size.width * progress - 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    if !current { player.load(meeting) }
                    player.seek(max(0, min(1, v.location.x / geo.size.width)) * total)
                })
            }
            .frame(height: 20)
            Text("\(timestamp(current ? player.currentTime : 0)) / \(timestamp(current ? player.duration : meeting.duration))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            Button("\(player.rate.formatted())x") { player.cycleRate() }.buttonStyle(.plain).font(.system(size: 11)).help("Click to change playback speed")
            Button("Transcribe") { try? model.store.setStatus(meeting.id, "queued"); model.enqueue(meeting.id) }
                .controlSize(.small).disabled(meeting.isProcessing)
            Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete Audio")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .confirmationDialog("Delete audio files?", isPresented: $confirmDelete) {
            Button("Delete Audio", role: .destructive) {
                player.stop()
                for f in (try? FileManager.default.contentsOfDirectory(at: meeting.folder, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        } message: { Text("The transcript and notes are kept. Audio files cannot be recovered once deleted.") }
    }
}
