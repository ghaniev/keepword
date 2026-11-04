import FluidAudio
import Foundation

/// 16 kHz mono samples and the cuts long recordings need: engines that take a limited amount of audio at a time
/// (cloud uploads, Whisper) get parts that end at a pause, and parts without sound are skipped.
enum SpeechAudio {
    static let sampleRate = 16_000.0

    static func load(_ url: URL) throws -> [Float] { try AudioConverter().resampleAudioFile(url) }

    private static let frame = Int(sampleRate / 10)  // 100 ms
    private static let soundLevel: Float = 0.002  // RMS, about -54 dBFS

    private static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }

    private static func frames(_ s: ArraySlice<Float>) -> [Range<Int>] {
        stride(from: s.startIndex, to: s.endIndex, by: frame).map { $0..<min($0 + frame, s.endIndex) }
    }

    static func hasSound(_ s: ArraySlice<Float>) -> Bool { frames(s).contains { rms(s[$0]) > soundLevel } }

    /// First to last sound in a part, in seconds from its start.
    static func speechSpan(_ s: ArraySlice<Float>) -> ClosedRange<Double>? {
        let loud = frames(s).filter { rms(s[$0]) > soundLevel }
        guard let a = loud.first, let b = loud.last else { return nil }
        return Double(a.lowerBound - s.startIndex) / sampleRate...Double(b.upperBound - s.startIndex) / sampleRate
    }

    /// Middle of the quietest 300 ms in `range`, so a cut doesn't fall inside a word.
    static func quietestCut(_ samples: [Float], in range: Range<Int>) -> Int {
        let window = frame * 3
        var best = (level: Float.infinity, at: range.lowerBound + range.count / 2)
        for start in stride(from: range.lowerBound, to: max(range.lowerBound + 1, range.upperBound - window), by: frame) {
            let level = rms(samples[start..<min(start + window, samples.count)])
            if level <= best.level { best = (level, start + window / 2) }  // the latest pause: parts close to the limit
        }
        return best.at
    }

    /// Parts of at most `maxSeconds`, each ending at a pause found in its last fifth.
    static func parts(_ samples: [Float], maxSeconds: Double) -> [Range<Int>] {
        let maxLength = Int(maxSeconds * sampleRate)
        var out: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let end = start + maxLength
            let cut = quietestCut(samples, in: end - maxLength / 5..<end)
            out.append(start..<cut)
            start = cut
        }
        if start < samples.count { out.append(start..<samples.count) }
        return out
    }
}
