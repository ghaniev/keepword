import AVFoundation
import FluidAudio
import Foundation

/// Live transcript while recording: one sliding-window Parakeet stream per source (mic / system),
/// confirmed text becomes bubbles, volatile text is the grey "typing" line. Display only —
/// the final transcript is redone from the files after the call.
@MainActor
final class LiveTranscript: ObservableObject {
    struct Line: Identifiable { let id = UUID(); let isMic: Bool; let text: String; let time: Double }
    @Published var lines: [Line] = []
    @Published var volatile: [Bool: String] = [:]
    @Published var status = ""

    private var streams: [Bool: (SlidingWindowAsrManager, AsyncStream<AVAudioPCMBuffer>.Continuation)] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var started = Date()

    func start(sources: [Bool]) async {
        lines = []
        volatile = [:]
        started = .now
        status = String(localized: "Loading speech model…")
        do {
            let models = try await LocalTranscriber.shared.liveModels()
            for isMic in sources {
                let manager = SlidingWindowAsrManager(config: .streaming)
                try await manager.loadModels(models)
                try await manager.startStreaming(source: isMic ? .microphone : .system)
                let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(200))
                streams[isMic] = (manager, cont)
                // Feed buffers in order through one task (actor calls from audio threads would reorder).
                tasks.append(Task.detached { for await b in stream { await manager.streamAudio(b) } })
                tasks.append(Task { [weak self] in
                    for await u in await manager.transcriptionUpdates {
                        guard let self else { return }
                        let text = u.text.trimmingCharacters(in: .whitespaces)
                        if u.isConfirmed {
                            if !text.isEmpty { self.lines.append(Line(isMic: isMic, text: text, time: Date().timeIntervalSince(self.started))) }
                            self.volatile[isMic] = nil
                        } else {
                            self.volatile[isMic] = text
                        }
                    }
                })
            }
            status = ""
        } catch {
            status = String(localized: "Live transcription unavailable: \(error.localizedDescription)")
        }
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer, isMic: Bool) {
        Task { @MainActor in self.streams[isMic]?.1.yield(buffer) }
    }

    func stop() {
        for (_, (manager, cont)) in streams {
            cont.finish()
            Task { await manager.cancel() }
        }
        streams = [:]
        tasks.forEach { $0.cancel() }
        tasks = []
        volatile = [:]
    }
}
