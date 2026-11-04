import AVFoundation
import GRDB
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Section: Hashable {
        case home, chat, calendar, actionItems, people, tags
        case documents(Store.Scope)
    }

    let store: Store
    let recorder = Recorder()
    let live = LiveTranscript()
    let calendar = CalendarService()
    let callDetector = CallDetector()
    let player = AudioPlayer()
    let mcp = MCPServer()
    let mcpClients = MCPConnections()
    let downloader = ModelDownloader()
    private var observer: AnyDatabaseCancellable?
    private var processing: Task<Void, Never>?
    private var clock: Timer?
    private var recordingStart = Date()
    private var pausedSince: Date?
    private var pausedTotal: TimeInterval = 0
    private var activity: NSObjectProtocol?

    /// Recording time from the wall clock, minus pauses (timer ticks get throttled by App Nap).
    var currentElapsed: Double {
        let now = Date()
        return now.timeIntervalSince(recordingStart) - pausedTotal - (pausedSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    @Published var section: Section = .documents(.all)
    @Published var selectedMeeting: String?
    @Published var selectedPerson: String?
    @Published var selectedChat: String?
    @Published var searchText = ""
    @Published var focusSearch = false
    @Published var revision = 0  // bumps on any DB change so views refetch
    @Published var toast: String?
    @Published var transcriptJump: (meeting: String, time: Double)?
    @Published var documentTab: DocumentTab = .summary
    @Published var pendingChatPrompt: String?
    @Published var identifyingSpeakers: String?  // meeting id whose speaker wizard is open
    @Published var runningQueries: Set<String> = []
    @Published var taskRequest: TaskRequest?
    /// Set to open the Permissions window (RootView owns openWindow).
    @Published var permissionsRequested = false
    @Published var respeaking: String?  // meeting id whose "Re-identify Speakers" sheet is open
    /// First launch with no AI configured shows the "Choose how to generate summaries" screen.
    @Published var showWelcome = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        && UserDefaults.standard.string(forKey: "llmBaseURL") == nil && !CommandLine.arguments.contains("--demo")

    @Published var recordingID: String?
    let meter = RecordingMeter()
    @Published var paused = false
    @Published var micMuted = false

    init() {
        var demoCalendar = false
        do {
            if CommandLine.arguments.contains("--demo") {
                // Throwaway library with sample meetings, for trying the UI without touching real data.
                Store.useTemporaryLibrary()
                store = try Store()
                try Demo.seed(store)
                demoCalendar = true
            } else {
                // Testing aid: `-libraryPath <dir>` opens a separate library (launch argument, never saved).
                if let path = UserDefaults.standard.string(forKey: "libraryPath"), !path.isEmpty { Store.dataDir = URL(filePath: path) }
                store = try Store()
            }
        } catch { fatalError("Cannot open database: \(error)") }
        observer = DatabaseRegionObservation(tracking: .fullDatabase)
            .start(in: store.db, onError: { _ in }) { [weak self] _ in
                DispatchQueue.main.async { self?.revision += 1 }
            }
        callDetector.onCallStarted = { [weak self] bundle in self?.callStarted(bundle) }
        callDetector.onCallEnded = { [weak self] in self?.callEnded() }
        if UserDefaults.standard.flag("callDetection", true) { callDetector.start() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Demo.snapshots(self, to: CommandLine.arguments[i + 1])
        }
        calendar.refresh()
        if demoCalendar { calendar.useDemoEvents(Demo.calendarEvents()) }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.calendar.refresh(); self?.checkScheduledMeetings(); self?.runDueQueries() }
        }
        if defaults.bool(forKey: "mcpEnabled") { startMCP() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            LlamaEngine.shutdownBlocking()
            MainActor.assumeIsolated { self?.mcpClients.stopAll() }
        }
        for m in (try? store.meetings(.all)) ?? [] where m.status == "recovered" { enqueue(m.id) }
        if !CommandLine.arguments.contains("--demo"), Embedder.modelID != defaults.string(forKey: "indexedEmbeddingModel") {
            reindexAll()
        }
    }

    /// Re-embeds every meeting with the current embedding source (vectors from different models can't be mixed).
    func reindexAll() {
        let ids = ((try? store.meetings(.all)) ?? []).map(\.id) + ((try? store.meetings(.deleted)) ?? []).map(\.id)
        let model = Embedder.modelID
        let previous = processing
        processing = Task.detached { [store] in
            await previous?.value
            for id in ids { await Pipeline.shared.index(id, store: store) }
            await MainActor.run { UserDefaults.standard.set(model, forKey: "indexedEmbeddingModel") }
        }
    }

    /// Deep links for Shortcuts / Raycast / scripts: meetnotes://record, stop, pause, bookmark, screenshot, open?id=…
    func handle(_ url: URL) {
        guard url.scheme == "meetnotes" else { return }
        switch url.host {
        case "record": if recordingID == nil { startRecording(title: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title" }?.value) }
        case "stop": stopRecording()
        case "pause": if recordingID != nil { togglePause() }
        case "bookmark": addBookmark()
        case "screenshot": takeScreenshot(area: false)
        case "download-model":
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
               let m = LocalModels.find(id) {
                downloader.download(m) { [weak self] in self?.toast = String(localized: "\(m.name) downloaded") }
            }
        case "simulate-device-change": if recordingID != nil { recorder.simulateDeviceChange() }  // testing aid
        case "transcribe":
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
                try? store.setStatus(id, "queued")
                enqueue(id)
            }
        case "summarize":
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
                enqueue(id, regenerateOnly: true)
            }
        case "open": if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value { open(id) }
        default: toast = String(localized: "Unknown link: \(url.absoluteString)")
        }
    }

    // MARK: - Screenshots

    func takeScreenshot(area: Bool) {
        guard let id = recordingID else { return }
        let time = currentElapsed
        Task {
            do {
                let url = try await ScreenCapture.capture(area: area)
                try store.attach(file: url, to: id, recordingTime: time)
                try? FileManager.default.removeItem(at: url)
                toast = String(localized: "Screenshot attached at \(timestamp(time))")
            } catch is CancellationError {
            } catch {
                toast = String(localized: "Couldn't capture screenshot: \(error.localizedDescription). Allow MeetNotes in System Settings → Privacy & Security → Screen & System Audio Recording.")
            }
        }
    }

    // MARK: - MCP server

    func startMCP() {
        do {
            let port = defaults.integer(forKey: "mcpPort")
            try mcp.start(port: UInt16(clamping: port > 0 ? port : 8765), store: store)
        } catch { toast = String(localized: "MCP server failed: \(error.localizedDescription)") }
    }

    // MARK: - Live queries

    func runQuery(_ q: SavedQuery) {
        guard !runningQueries.contains(q.id) else { return }
        runningQueries.insert(q.id)
        Task {
            await LiveQueries.run(q, store: store)
            runningQueries.remove(q.id)
        }
    }

    private func runDueQueries() {
        for q in (try? store.savedQueries()) ?? [] where q.nextRunAt.map({ $0 <= .now }) == true { runQuery(q) }
    }

    // MARK: - Recording

    var defaults: UserDefaults { .standard }

    func toggleRecording() {
        if recordingID != nil { stopRecording() } else { startRecording() }
    }

    private var startingRecording = false  // a start is in flight; a second press must not start another

    func startRecording(title: String? = nil, event: CalEvent? = nil) {
        guard recordingID == nil, !startingRecording else { return }
        startingRecording = true
        Task {
            defer { startingRecording = false }
            let mode = RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .both
            if mode != .systemOnly, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                toast = String(localized: "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
                permissionsRequested = true
                return
            }
            var m = Meeting.new(title: title ?? event?.title ?? String(localized: "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"))
            m.eventId = event?.id
            // Attendees (you included) bound how many voices diarization may find on the call.
            if let n = event?.attendees.count, n > 1 { m.maxSpeakers = n }
            if case .documents(.folder(let fid)) = section { m.folderId = fid }
            let liveOn = defaults.flag("liveTranscription", true)
            recorder.onMicBuffer = liveOn ? { [live] in live.feed($0, isMic: true) } : nil
            recorder.onSystemBuffer = liveOn ? { [live] in live.feed($0, isMic: false) } : nil
            recorder.onDeviceChange = { [weak self] track, name in
                Task { @MainActor in
                    self?.toast = name.map { String(localized: "\(track) switched to \($0) — recording continues") }
                        ?? "\(track) was lost and could not be restored. The rest of the recording keeps the other track."
                }
            }
            recorder.onMicBlocked = { [weak self] in
                Task { @MainActor in
                    self?.toast = String(localized: "The microphone is delivering silence — macOS is blocking it. Turn MeetNotes on in System Settings → Privacy & Security → Microphone (rebuilt copies may need it again).")
                }
            }
            recorder.onLevel = { [weak self] level, isMic in
                Task { @MainActor in
                    guard let self else { return }
                    if isMic { self.meter.mic = level } else { self.meter.system = level }
                }
            }
            let (recorder, folder, inputUID) = (recorder, m.folder, defaults.string(forKey: "inputDeviceUID"))
            do {
                try store.save(m)
                // CoreAudio can hang inside start when the system audio service (coreaudiod) is stuck;
                // say so instead of an endless silent "recording".
                let watchdog = Task { [weak self] in
                    try await Task.sleep(for: .seconds(8))
                    self?.toast = String(localized: "macOS audio isn't responding, so recording can't start. Restart the audio service in Terminal: sudo killall coreaudiod")
                }
                defer { watchdog.cancel() }
                do {
                    try await audio { try recorder.start(in: folder, mode: mode, inputDeviceUID: inputUID) }
                } catch let warning as RecorderWarning {
                    toast = warning.localizedDescription
                    if Permission.systemAudio.status != .granted { permissionsRequested = true }
                }
            } catch {
                try? await audio { recorder.stop() }
                try? store.setStatus(m.id, "error:\(error.localizedDescription)")
                toast = error.localizedDescription
                return
            }
            recordingID = m.id
            meter.elapsed = 0
            recordingStart = .now
            pausedSince = nil
            pausedTotal = 0
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting")
            paused = false
            micMuted = false
            section = .documents(.all)
            selectedMeeting = m.id
            documentTab = .transcript
            // Ticks 4×/s and publishes only when the second changes: a 1 s timer drifts against the
            // wall clock and skips or repeats seconds. `.common` keeps it running while a menu is open.
            let clock = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let seconds = self.currentElapsed.rounded(.down)
                    if seconds != self.meter.elapsed { self.meter.elapsed = seconds }
                }
            }
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
            if defaults.flag("meetingOverlay", true) { MeetingOverlay.shared.show(self) }
            if liveOn { await live.start(sources: mode == .both ? [true, false] : [mode == .micOnly]) }
        }
    }

    func stopRecording() {
        guard let id = recordingID else { return }
        let recorder = recorder
        live.stop()
        MeetingOverlay.shared.close()
        clock?.invalidate()
        let duration = currentElapsed
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        recordingID = nil
        meter.mic = 0
        meter.system = 0
        Task {
            try? await audio { recorder.stop() }  // files are closed before processing reads them
            try? store.update(id) { $0.duration = duration; $0.status = "queued" }
            enqueue(id)
        }
    }

    private var audioOp: Task<Void, Error>?
    /// Runs a recorder start/stop off the main thread, one after another: CoreAudio calls can block for
    /// seconds (device changes, permission checks), and a quick stop → record must not overlap.
    private func audio(_ work: @escaping @Sendable () throws -> Void) async throws {
        let previous = audioOp
        let op = Task.detached {
            _ = try? await previous?.value
            try work()
        }
        audioOp = op
        try await op.value
    }

    func togglePause() {
        paused.toggle()
        recorder.paused = paused
        if paused { pausedSince = .now } else if let since = pausedSince { pausedTotal += Date.now.timeIntervalSince(since); pausedSince = nil }
    }

    func toggleMute() {
        micMuted.toggle()
        recorder.micMuted = micMuted
    }

    func addBookmark() {
        guard let id = recordingID else { return }
        let time = currentElapsed
        try? store.addBookmark(id, at: time)
        toast = String(localized: "Bookmark added at \(timestamp(time))")
    }

    /// Processing runs one meeting at a time (the speech models are shared).
    func enqueue(_ id: String, regenerateOnly: Bool = false) {
        let previous = processing
        processing = Task.detached { [store, self] in
            await previous?.value
            if regenerateOnly {
                do { try await Pipeline.shared.summarize(id, store: store) } catch { try? store.setStatus(id, "error:\(error.localizedDescription)") }
            } else if let notice = await Pipeline.shared.process(id, store: store) {
                await MainActor.run { self.toast = notice }
            }
        }
    }

    func cleanUp(_ id: String) {
        let previous = processing
        processing = Task.detached { [store] in
            await previous?.value
            try? store.setStatus(id, "processing:cleanup")
            await Pipeline.shared.cleanup(id, store: store)
            try? store.setStatus(id, "done")
        }
    }

    // MARK: - Import

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(importFile) }
    }

    func importFile(_ url: URL) {
        var m = Meeting.new(title: url.deletingPathExtension().lastPathComponent)
        m.status = "queued"
        if case .documents(.folder(let fid)) = section { m.folderId = fid }
        Task {
            do {
                try FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
                let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
                if isVideo {
                    // Keep only the audio track; the speech stack reads audio files.
                    guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
                        throw LLMError(message: "Failed to extract audio from video")
                    }
                    try await export.export(to: m.folder.appending(path: "import.m4a"), as: .m4a)
                } else {
                    try FileManager.default.copyItem(at: url, to: m.folder.appending(path: "import.\(url.pathExtension.lowercased())"))
                }
                try store.save(m)
                section = .documents(.all)
                selectedMeeting = m.id
                enqueue(m.id)
                toast = String(localized: "File imported")
            } catch {
                toast = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Navigation helpers

    func open(_ meetingID: String, at time: Double? = nil) {
        searchText = ""
        if case .documents = section {} else { section = .documents(.all) }
        selectedMeeting = meetingID
        if let time {
            documentTab = .transcript
            transcriptJump = (meetingID, time)
        }
    }

    func trash(_ id: String) {
        try? store.trash(id)
        if selectedMeeting == id { selectedMeeting = nil }
        toast = String(localized: "Moved to Recently Deleted")
    }

    // MARK: - Call detection & calendar prompts

    private var promptedEvents = Set<String>()

    private func callStarted(_ bundle: String) {
        guard recordingID == nil else { return }
        let app = CallDetector.conferencing[bundle] ?? bundle
        let event = calendar.upcoming.first { $0.start.addingTimeInterval(-600) < .now && $0.end > .now }
        FloatingPrompt.shared.show(
            title: "Record this meeting?",
            message: event.map { "\($0.title) · \(app)" } ?? "\(app) is using the microphone",
            primary: ("Record", { [weak self] in self?.startRecording(event: event) }),
            secondary: ("Ignore \(app)", {
                var ignored = UserDefaults.standard.stringArray(forKey: "ignoredCallApps") ?? []
                ignored.append(bundle)
                UserDefaults.standard.set(ignored, forKey: "ignoredCallApps")
            }))
    }

    private func callEnded() {
        guard recordingID != nil, defaults.flag("autoStopPrompt", true) else { return }
        FloatingPrompt.shared.show(title: String(localized: "Call ended?"), message: String(localized: "No one else is using the microphone."),
                                   primary: (String(localized: "Stop Recording"), { [weak self] in self?.stopRecording() }),
                                   secondary: (String(localized: "Keep Recording"), {}))
    }

    /// Calendar meetings with a video link get a "Record this meeting?" prompt when they start.
    private func checkScheduledMeetings() {
        guard recordingID == nil, defaults.flag("promptForCalendarMeetings", true) else { return }
        for e in calendar.upcoming where abs(e.start.timeIntervalSinceNow) < 90 && e.videoLink != nil {
            guard promptedEvents.insert(e.id).inserted else { continue }
            FloatingPrompt.shared.show(title: String(localized: "Record this meeting?"), message: e.title,
                                       primary: (String(localized: "Join & Record"), { [weak self] in
                                           if let url = e.videoLink { NSWorkspace.shared.open(url) }
                                           self?.startRecording(event: e)
                                       }),
                                       secondary: (String(localized: "Not Now"), {}))
        }
    }
}

enum DocumentTab: Hashable { case summary, transcript, chat }
