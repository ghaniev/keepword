import SwiftUI

/// Recording clock and input levels. Kept out of AppModel: levels change many times a second,
/// and every AppModel change redraws the whole window (which starved the clock).
@MainActor
final class RecordingMeter: ObservableObject {
    @Published var elapsed: Double = 0  // whole seconds
    @Published var mic: Float = 0
    @Published var system: Float = 0
}

struct RecordingTimeText: View {
    @ObservedObject var meter: RecordingMeter
    var body: some View { Text(timestamp(meter.elapsed)).monospacedDigit() }
}

/// Mic and system level bars (two views, laid out by the parent stack).
struct RecordingLevels: View {
    @ObservedObject var meter: RecordingMeter
    let micMuted: Bool
    var body: some View {
        LevelBar(level: meter.mic, icon: micMuted ? "mic.slash.fill" : "mic.fill")
        LevelBar(level: meter.system, icon: "speaker.wave.2.fill")
    }
}
