import AVFoundation
import CoreAudio

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError(what: what, status: status) }
}

private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ type: T.Type) -> [T] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    return [T](unsafeUninitializedCapacity: count) { buf, n in
        n = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf.baseAddress!) == noErr ? count : 0
    }
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
    var addr = address(selector, scope)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

private func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

enum AudioDevices {
    struct Device: Identifiable, Hashable { let id: String; let name: String }

    static func inputs() -> [Device] {
        readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID.self).compactMap { dev in
            var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0,
                  let uid = readString(dev, kAudioDevicePropertyDeviceUID),
                  let name = readString(dev, kAudioObjectPropertyName) else { return nil }
            return Device(id: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID.self)
            .first { readString($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputName() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        return readString(device, kAudioObjectPropertyName)
    }

    static func defaultOutputUID() throws -> String {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "default output device")
        guard let uid = readString(device, kAudioDevicePropertyDeviceUID) else { throw CoreAudioError(what: "output device UID", status: -1) }
        return uid
    }

    /// Bundle ids of other apps currently capturing from any microphone (Core Audio process objects, macOS 14.2+).
    /// This tells "a call is running" from "someone just plays music".
    static func appsUsingMicrophone() -> [String] {
        let me = Bundle.main.bundleIdentifier
        return readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, AudioObjectID.self)
            .compactMap { p in
                guard readUInt32(p, kAudioProcessPropertyIsRunningInput) == 1,
                      let bundle = readString(p, kAudioProcessPropertyBundleID), !bundle.isEmpty, bundle != me else { return nil }
                return bundle
            }
    }
}

/// Core Audio process tap (macOS 14.2+): taps everything the Mac plays, wraps the tap in a private
/// aggregate device and pulls buffers with an IOProc.
/// Needs NSAudioCaptureUsageDescription in Info.plist; macOS asks for "System Audio Recording" once.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private var handler: ((AVAudioPCMBuffer) -> Bool)?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "meetnotes.systemtap")
    private let control = DispatchQueue(label: "meetnotes.systemtap.control")
    var onDeviceChange: ((String?) -> Void)?

    /// `handler` returns false to skip writing (paused).
    func start(writingTo url: URL, handler: @escaping (AVAudioPCMBuffer) -> Bool) throws {
        self.handler = handler
        let format = try startDevice()
        writer = try TrackWriter(url: url, format: format)
        // The aggregate device is built on the current output; when the output changes (AirPods…) rebuild it.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputDeviceChanged() }
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, listener)
        outputListener = listener
    }

    /// Builds tap + aggregate device on the current default output and starts pulling buffers. Returns the tap format.
    @discardableResult
    private func startDevice() throws -> AVAudioFormat {
        // We play no audio ourselves except transcript playback; exclude nothing.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CoreAudioError(what: "tap format", status: -1) }

        let outputUID = try AudioDevices.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Keepword Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
                guard let self, let writer = self.writer,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                      self.handler?(buffer) == true else { return }
                // ponytail: disk write on the IO queue; move to a ring buffer if you hear dropouts
                writer.write(buffer)
            }, "create IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
        return format
    }

    private func stopDevice() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        queue.sync {}  // let an in-flight IOProc finish
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Default output changed: rebuild on the new output, same file; the switch-over time becomes silence.
    func outputDeviceChanged() {
        control.async { [weak self] in
            guard let self, self.writer != nil else { return }
            self.writer?.markGap()
            self.stopDevice()
            for attempt in 0..<10 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
                guard self.writer != nil else { return }
                if (try? self.startDevice()) != nil {
                    self.onDeviceChange?(AudioDevices.defaultOutputName() ?? "default output")
                    return
                }
                self.stopDevice()
            }
            self.onDeviceChange?(nil)
        }
    }

    func stop() {
        if let outputListener {
            var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, outputListener)
        }
        outputListener = nil
        control.sync {
            stopDevice()
            queue.sync { writer = nil }  // closes the file
        }
        handler = nil
    }
}
