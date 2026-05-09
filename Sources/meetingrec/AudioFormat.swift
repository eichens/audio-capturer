import Foundation
import AVFoundation

enum AudioFormat {
    static let targetSampleRate: Double = 16_000

    /// Canonical 16kHz mono Float32 non-interleaved format used internally.
    static func mono16k() -> AVAudioFormat {
        // Using the standard (non-interleaved, deinterleaved Float32) AVAudioFormat
        // convenience initializer keeps AVAudioConverter happy.
        return AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
    }
}

/// Wraps AVAudioConverter to convert an input PCM buffer to 16kHz mono Float32.
/// Handles sample-rate conversion AND channel downmix in one step — per AVAudioConverter
/// docs it will average channels when going from N→1 by default.
final class Mono16kConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init(inputFormat: AVAudioFormat) throws {
        self.outputFormat = AudioFormat.mono16k()
        guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "meetingrec", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create AVAudioConverter from \(inputFormat) to \(outputFormat)"
            ])
        }
        self.converter = c
    }

    /// Converts an input buffer to 16kHz mono Float32. Returns the converted samples
    /// as a flat [Float] array (since the output is mono, non-interleaved == interleaved).
    /// May return an empty array if the converter needs more input to produce output.
    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        // Pick an output capacity sized to the input duration at the target rate,
        // with generous headroom so the converter never reports .outputBufferFull
        // before consuming the whole input.
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            return []
        }

        // AVAudioConverter works with a pull-style callback. We supply `input` exactly
        // once and then return .noDataNow so the converter stops asking for more and
        // flushes what it has.
        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error, let convError = convError {
            throw convError
        }

        let frames = Int(outBuf.frameLength)
        guard frames > 0, let channelData = outBuf.floatChannelData else { return [] }
        let ptr = channelData[0]
        return Array(UnsafeBufferPointer(start: ptr, count: frames))
    }
}
