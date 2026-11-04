import AVFoundation
import CoreAudio
import os

enum RecordingMode: String, CaseIterable, Identifiable {
    case both, micOnly, systemOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: String(localized: "Microphone + System Audio")
        case .micOnly: String(localized: "Microphone Only")
        case .systemOnly: String(localized: "System Audio Only")
        }
    }
}

/// Records the microphone and the Mac's audio output into two separate files (mic.caf, system.caf),
/// with no bot and no virtual driver. Buffers are also handed to live transcription.
/// Survives device changes mid-call (AirPods connect/disconnect, another mic, another output).
final class Recorder {
    private var engine = AVAudioEngine()  // replaced on every mic (re)start; touched only on micQueue
    private var mic: TrackWriter?
    private let tap = SystemAudioTap()
    private let flags = OSAllocatedUnfairLock(initialState: (paused: false, micMuted: false))
    private var zeroMicSeconds: Double = 0  // touched only on the mic tap thread
    private var inputDeviceUID: String?
    private var configObserver: NSObjectProtocol?
    private let micQueue = DispatchQueue(label: "meetnotes.mic-restart")
    private var restartGeneration = 0

    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float, Bool) -> Void)?  // (rms 0…1, isMic), at most ~15 times a second per track
    // Last level callback per track; each is touched only by its own audio thread.
    private var lastMicLevel: TimeInterval = 0
    private var lastSystemLevel: TimeInterval = 0
    /// Fired once when the mic delivers exact digital silence for a few seconds: macOS is withholding access
    /// (typical after rebuilding an ad-hoc signed app), not a quiet room.
    var onMicBlocked: (() -> Void)?
    /// A device changed and recording continues: ("Microphone", device name) or ("System audio", output name),
    /// or a nil name when the device could not be recovered.
    var onDeviceChange: ((String, String?) -> Void)?

    var paused: Bool {
        get { flags.withLock { $0.paused } }
        set { flags.withLock { $0.paused = newValue } }
    }
    var micMuted: Bool {
        get { flags.withLock { $0.micMuted } }
        set { flags.withLock { $0.micMuted = newValue } }
    }

    func start(in dir: URL, mode: RecordingMode, inputDeviceUID: String?) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paused = false
        micMuted = false
        zeroMicSeconds = 0
        self.inputDeviceUID = inputDeviceUID
        // System audio first: creating its aggregate device reconfigures audio hardware, which would
        // otherwise hit an already running mic engine with a configuration change right at the start.
        var warning: RecorderWarning?
        if mode != .micOnly {
            tap.onDeviceChange = { [weak self] name in self?.onDeviceChange?("System audio", name) }
            do {
                try tap.start(writingTo: dir.appending(path: "system.caf")) { [weak self] buffer in
                    guard let self, !self.paused else { return false }
                    if let copy = buffer.copy() { self.onSystemBuffer?(copy) }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastSystemLevel >= 1.0 / 15 { self.lastSystemLevel = now; self.onLevel?(buffer.rms, false) }
                    return true
                }
            } catch where mode == .both {
                // Keep the mic recording; the caller reports that system audio is unavailable.
                tap.stop()
                warning = .systemAudioUnavailable(error.localizedDescription)
            }
        }
        if mode != .systemOnly {
            try micQueue.sync {
                try startMic()
                mic = try TrackWriter(url: dir.appending(path: "mic.caf"), format: engine.inputNode.outputFormat(forBus: 0))
            }
        }
        if let warning { throw warning }
    }

    /// A chosen mic that is gone falls back to the system default (AVAudioEngine's own behaviour).
    /// Call on micQueue.
    private func selectInputDevice() {
        guard let uid = inputDeviceUID, var id = AudioDevices.deviceID(forUID: uid), let unit = engine.inputNode.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Starts the mic on a fresh engine (call on micQueue). A reused engine keeps the previous device's
    /// formats after a hardware change, and installTap then raises an Objective-C exception that aborts the app.
    private func startMic() throws {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine = AVAudioEngine()
        selectInputDevice()
        // Fires when the input/output hardware changes (AirPods, USB mic, sample rate); the engine stops itself.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in self?.micDeviceChanged() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CoreAudioError(what: "microphone format", status: -1) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, !self.paused else { return }
            if self.micMuted {
                buffer.silence()
            } else if buffer.isDigitalSilence {
                self.zeroMicSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
                if self.zeroMicSeconds >= 4, self.zeroMicSeconds - Double(buffer.frameLength) / buffer.format.sampleRate < 4 { self.onMicBlocked?() }
            } else {
                self.zeroMicSeconds = 0
            }
            self.mic?.write(buffer)
            self.onMicBuffer?(buffer)
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastMicLevel >= 1.0 / 15 { self.lastMicLevel = now; self.onLevel?(buffer.rms, true) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Re-attach the mic after a hardware change. Bluetooth headsets can take several seconds to settle,
    /// so keep retrying for ~10 s before giving up (Meetily gives Bluetooth a similar grace period).
    private func micDeviceChanged() {
        micQueue.async { [weak self] in
            guard let self, self.mic != nil else { return }
            self.restartGeneration += 1
            let generation = self.restartGeneration
            // Let the hardware settle: a burst of changes restarts once. Opening a Bluetooth mic (AirPods)
            // switches the headset to call mode and posts a change for the engine we just started; restarting
            // on every such change opened the mic again, switched again, and looped without recording.
            self.micQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, generation == self.restartGeneration, self.mic != nil else { return }
                if self.engine.isRunning { return }  // the change didn't stop it: keep recording
                self.restartMic(generation)
            }
        }
    }

    /// Call on micQueue.
    private func restartMic(_ generation: Int) {
        mic?.markGap()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        for attempt in 0..<10 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            guard generation == restartGeneration, mic != nil else { return }  // newer change or stopped
            do {
                try startMic()
                onDeviceChange?("Microphone", AVCaptureDevice.default(for: .audio)?.localizedName ?? "default input")
                return
            } catch {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        onDeviceChange?("Microphone", nil)
    }

    func stop() {
        micQueue.sync {
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            restartGeneration += 1
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            mic = nil  // closes the file
        }
        tap.stop()
    }

    /// Test hook: simulate a hardware change on both tracks.
    func simulateDeviceChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: micQueue.sync { engine })
        tap.outputDeviceChanged()
    }
}

enum RecorderWarning: LocalizedError {
    case systemAudioUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .systemAudioUnavailable(let why):
            "System audio unavailable (\(why)). Recording microphone only — check System Settings → Privacy & Security → Screen & System Audio Recording."
        }
    }
}
