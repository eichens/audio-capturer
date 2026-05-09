import Foundation

/// Pulls equal-sized chunks from the mic and system ring buffers, interleaves them
/// as stereo (mic=L, system=R), converts Float32 → Int16 with clipping, and appends
/// to the WAV writer. Runs on its own dispatch queue and polls periodically.
///
/// Time-alignment strategy (v1): we wait until both buffers have at least `chunkSize`
/// samples. Neither stream's samples are dropped; whichever is slower simply makes
/// the mixer wait. Over a long recording the two clocks will drift, but for speech
/// transcription the drift is immaterial.
final class StereoMixer {
    private let micBuffer: FloatRingBuffer
    private let systemBuffer: FloatRingBuffer
    private let writer: WAVWriter
    private let errorHandler: (Error) -> Void
    private let queue = DispatchQueue(label: "meetingrec.mixer")
    private var running = false
    private let chunkSize: Int
    private let pollInterval: DispatchTimeInterval

    init(
        micBuffer: FloatRingBuffer,
        systemBuffer: FloatRingBuffer,
        writer: WAVWriter,
        chunkSize: Int = 1600,           // 100ms @ 16kHz
        pollIntervalMS: Int = 20,
        errorHandler: @escaping (Error) -> Void
    ) {
        self.micBuffer = micBuffer
        self.systemBuffer = systemBuffer
        self.writer = writer
        self.chunkSize = chunkSize
        self.pollInterval = .milliseconds(pollIntervalMS)
        self.errorHandler = errorHandler
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.running = true
            self.loop()
        }
    }

    /// Stops the polling loop and drains whatever equal-sized pairs remain in both
    /// buffers. Any trailing imbalance (e.g. mic has 500 more samples than system)
    /// is discarded — padding with silence would introduce a misaligned tail.
    func stopAndFlush() {
        queue.sync {
            self.running = false
            self.drain()
        }
    }

    private func loop() {
        guard running else { return }
        mixOnePassIfReady()
        queue.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.loop()
        }
    }

    private func mixOnePassIfReady() {
        while micBuffer.available >= chunkSize && systemBuffer.available >= chunkSize {
            writeOneChunk()
        }
    }

    private func drain() {
        while micBuffer.available >= chunkSize && systemBuffer.available >= chunkSize {
            writeOneChunk()
        }
    }

    private func writeOneChunk() {
        guard let mic = micBuffer.pop(count: chunkSize),
              let sys = systemBuffer.pop(count: chunkSize) else { return }

        var interleaved = [Int16](repeating: 0, count: chunkSize * 2)
        for i in 0..<chunkSize {
            interleaved[2 * i]     = floatToInt16(mic[i])
            interleaved[2 * i + 1] = floatToInt16(sys[i])
        }
        do {
            try writer.append(interleavedInt16: interleaved)
        } catch {
            errorHandler(error)
        }
    }

    /// Clip-safe Float32 → Int16 conversion. Input is assumed to be in [-1, 1] but
    /// we clamp defensively — some sources can momentarily exceed full scale.
    @inline(__always)
    private func floatToInt16(_ x: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, x))
        return Int16(clamped * Float(Int16.max))
    }
}
