import Foundation

/// Downloads on-device speech models with progress and cancel. Shared, so a download keeps going
/// when the Settings window closes.
@MainActor
final class SpeechModelDownloader: ObservableObject {
    static let shared = SpeechModelDownloader()
    @Published var progress: [String: Double] = [:]  // model id → 0…1 while downloading
    @Published var preparing: Set<String> = []  // downloaded, compiling for this Mac
    @Published var error: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    func isBusy(_ m: SpeechModel) -> Bool { tasks[m.id] != nil }

    func download(_ m: SpeechModel, then done: @escaping () -> Void = {}) {
        guard tasks[m.id] == nil else { return }
        if m.isDownloaded { return done() }
        error = nil
        let free = (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free > m.bytes * 2 + 1_000_000_000 else {
            error = String(localized: "Not enough disk space for \(m.name) (\(m.sizeLabel)).")
            return
        }
        progress[m.id] = 0
        tasks[m.id] = Task {
            let id = m.id
            let report: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in if self?.tasks[id] != nil { self?.progress[id] = min(p, 1) } }
            }
            do {
                try await m.download(progress: report) { Task { @MainActor [weak self] in self?.preparing.insert(id) } }
                try Task.checkCancellation()
                finish(id)
                done()
            } catch {
                // Never leave half a model behind: it would look downloaded to the loaders.
                try? FileManager.default.removeItem(at: m.folder)
                if !Task.isCancelled && !(error is CancellationError) {
                    self.error = String(localized: "Download of \(m.name) failed: \(error.localizedDescription)")
                }
                finish(id)
            }
        }
    }

    func cancel(_ m: SpeechModel) {
        tasks[m.id]?.cancel()
        finish(m.id)
    }

    func delete(_ m: SpeechModel) {
        Task {
            await LocalTranscriber.shared.unload(m)
            await WhisperTranscriber.shared.unload()
        }
        try? FileManager.default.removeItem(at: m.folder)
        if UserDefaults.standard.string(forKey: "localSpeechModel") == m.id { UserDefaults.standard.removeObject(forKey: "localSpeechModel") }
        objectWillChange.send()
    }

    private func finish(_ id: String) {
        tasks[id] = nil
        progress[id] = nil
        preparing.remove(id)
        objectWillChange.send()
    }
}
