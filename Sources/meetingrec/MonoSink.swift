import Foundation

/// Speaker-only counterpart to StereoMixer. Pulls fixed-size chunks from a single
/// ring buffer (the system-audio stream), converts Float32 → Int16 with clipping,
/// and appends to a mono WAV writer.
///
/// Unlike StereoMixer there's no second stream to align against, so on shutdown
/// we drain whatever remains — including a final partial chunk — instead of
/// dropping a trailing imbalance.
final class MonoSink {
    private let buffer: FloatRingBuffer
    private let writer: WAVWriter
    private let errorHandler: (Error) -> Void
    private let queue = DispatchQueue(label: "meetingrec.mono-sink")
    private var running = false
    private let chunkSize: Int
    private let pollInterval: DispatchTimeInterval

    init(
        buffer: FloatRingBuffer,
        writer: WAVWriter,
        chunkSize: Int = 1600,           // 100ms @ 16kHz
        pollIntervalMS: Int = 20,
        errorHandler: @escaping (Error) -> Void
    ) {
        self.buffer = buffer
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

    /// Stops the polling loop and drains whatever samples remain, including the
    /// final sub-chunk. Safe to call once.
    func stopAndFlush() {
        queue.sync {
            self.running = false
            self.drain()
        }
    }

    private func loop() {
        guard running else { return }
        while buffer.available >= chunkSize {
            writeOneChunk(count: chunkSize)
        }
        queue.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.loop()
        }
    }

    private func drain() {
        while buffer.available >= chunkSize {
            writeOneChunk(count: chunkSize)
        }
        let tail = buffer.available
        if tail > 0 {
            writeOneChunk(count: tail)
        }
    }

    private func writeOneChunk(count n: Int) {
        guard let samples = buffer.pop(count: n) else { return }
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = floatToInt16(samples[i])
        }
        do {
            try writer.append(interleavedInt16: out)
        } catch {
            errorHandler(error)
        }
    }

    @inline(__always)
    private func floatToInt16(_ x: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, x))
        return Int16(clamped * Float(Int16.max))
    }
}
