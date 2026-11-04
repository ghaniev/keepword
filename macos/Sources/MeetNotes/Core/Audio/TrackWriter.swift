import AVFoundation

/// Writes one track (mic.caf / system.caf) in a fixed format. When the device changes mid-call it converts the new
/// device's format to the file's, and fills the switch-over time with silence so both tracks stay on one timeline.
final class TrackWriter {
    let file: AVAudioFile
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var gapStart: Date?

    init(url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
    }

    /// The device went away; time from now until the next buffer becomes silence.
    func markGap() { lock.withLock { if gapStart == nil { gapStart = Date() } } }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if let g = gapStart {
                gapStart = nil
                writeSilence(seconds: Date().timeIntervalSince(g))
            }
            let target = file.processingFormat
            if buffer.format == target {
                try? file.write(from: buffer)
                return
            }
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if out.frameLength > 0 { try? file.write(from: out) }
        }
    }

    private func writeSilence(seconds: Double) {
        var remaining = AVAudioFrameCount(min(seconds, 600) * file.processingFormat.sampleRate)
        while remaining > 0 {
            let n = min(remaining, 48_000)
            guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return }
            b.frameLength = n
            b.silence()
            try? file.write(from: b)
            remaining -= n
        }
    }
}

extension AVAudioPCMBuffer {
    var rms: Float {
        guard let ch = floatChannelData, frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(frameLength) { sum += ch[0][i] * ch[0][i] }
        return min(1, (sum / Float(frameLength)).squareRoot() * 4)
    }

    var isDigitalSilence: Bool {
        guard let ch = floatChannelData, frameLength > 0 else { return false }
        for i in 0..<Int(frameLength) where ch[0][i] != 0 { return false }
        return true
    }

    func silence() {
        for buf in UnsafeMutableAudioBufferListPointer(mutableAudioBufferList) {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
    }

    /// Deep copy: tap buffers point into Core Audio memory that is reused after the IOProc returns.
    func copy() -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        out.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sd = s.mData, let dd = d.mData else { continue }
            memcpy(dd, sd, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }
}
