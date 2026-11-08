import SwiftUI

/// Record pill + import button; while recording: timer, pause, mute, bookmark and level meters.
struct RecordControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: model.toggleRecording) {
                    HStack(spacing: 7) {
                        if model.recordingID == nil {
                            Image(systemName: "waveform").font(.system(size: 13, weight: .semibold))
                            Text("Record").font(.system(size: 13, weight: .medium))
                        } else {
                            Image(systemName: "stop.fill").font(.system(size: 11))
                            RecordingTimeText(meter: model.meter).font(.system(size: 13, weight: .medium))
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 9).fill(model.recordingID == nil ? Palette.brand : Color.red))
                }
                .buttonStyle(.plain)
                .help(model.recordingID == nil ? "Start Recording (⌘R)" : "Stop Recording (⌘R)")

                Button(action: model.importWithPanel) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 14))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain).help("Import Audio/Video…")
            }
            if model.recordingID != nil {
                HStack(spacing: 10) {
                    if model.paused { Image(systemName: "pause.fill").foregroundStyle(.orange) } else { PulsingDot() }
                    RecordingLevels(meter: model.meter, micMuted: model.micMuted)
                    Spacer()
                    iconButton(model.paused ? "play.fill" : "pause.fill", model.paused ? "Resume Recording" : "Pause Recording", model.togglePause)
                    iconButton(model.micMuted ? "mic.slash" : "mic", model.micMuted ? "Unmute microphone" : "Mute microphone", model.toggleMute)
                    iconButton("bookmark", "Add bookmark (⌘B)", model.addBookmark)
                }
                .font(.system(size: 12))
            }
        }
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }
}

struct LevelBar: View {
    let level: Float
    let icon: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.green).frame(width: 26 * CGFloat(level))
            }
            .frame(width: 26, height: 4)
        }
    }
}
