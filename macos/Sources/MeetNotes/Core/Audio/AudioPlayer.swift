import AVFoundation
import Foundation

/// Plays mic + system tracks in sync, with speed control.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1
    private var players: [AVAudioPlayer] = []
    private var timer: Timer?
    private(set) var meetingID: String?
    private var stopAt: Double?

    func load(_ meeting: Meeting) {
        guard meetingID != meeting.id else { return }
        stop()
        meetingID = meeting.id
        let files = (try? FileManager.default.contentsOfDirectory(at: meeting.folder, includingPropertiesForKeys: nil)) ?? []
        players = files.filter { ["caf", "m4a", "wav", "mp3", "aac"].contains($0.pathExtension.lowercased()) }
            .compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach { $0.enableRate = true; $0.prepareToPlay() }
        duration = players.map(\.duration).max() ?? 0
        currentTime = 0
    }

    var hasAudio: Bool { !players.isEmpty }

    func toggle() { isPlaying ? pause() : play() }

    func play(from time: Double? = nil) {
        guard let first = players.first else { return }
        if let time { seek(time) }
        let start = first.deviceCurrentTime + 0.05
        for p in players { p.rate = rate; p.play(atTime: start) }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.players.map(\.currentTime).max() ?? 0
                if !self.players.contains(where: \.isPlaying) || (self.stopAt.map { self.currentTime >= $0 } ?? false) { self.pause() }
            }
        }
    }

    /// Plays one excerpt and stops at its end (speaker wizard).
    func playClip(from start: Double, to end: Double) {
        play(from: max(0, start - 0.2))
        stopAt = end + 0.3
    }

    func pause() {
        stopAt = nil
        players.forEach { $0.pause() }
        isPlaying = false
        timer?.invalidate()
    }

    func seek(_ time: Double) {
        let wasPlaying = isPlaying
        pause()
        for p in players { p.currentTime = min(time, p.duration) }
        currentTime = time
        if wasPlaying { play() }
    }

    func cycleRate() {
        let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
        rate = rates[((rates.firstIndex(of: rate) ?? 0) + 1) % rates.count]
        players.forEach { $0.rate = rate }
    }

    func stop() {
        pause()
        players = []
        meetingID = nil
        duration = 0
        currentTime = 0
    }
}
