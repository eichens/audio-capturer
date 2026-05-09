import Foundation

/// Simple lock-protected ring buffer of Float32 samples. Producers call `append`,
/// a single consumer pops fixed-size chunks once both ring buffers have enough data.
///
/// Capacity is sized generously (a few seconds of audio at 16kHz) so bursts from
/// either capture source can be absorbed without blocking. If the buffer fills,
/// the oldest samples are dropped — this shouldn't happen in practice, but it's
/// a safer failure mode than unbounded memory growth.
final class FloatRingBuffer {
    private var storage: [Float]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        lock.lock(); defer { lock.unlock() }

        var n = samples.count
        // If the incoming chunk is bigger than capacity, only the tail fits.
        var srcOffset = 0
        if n > capacity {
            srcOffset = n - capacity
            n = capacity
        }

        // If we'd overflow, advance the read pointer (drop oldest).
        if count + n > capacity {
            let drop = (count + n) - capacity
            readIndex = (readIndex + drop) % capacity
            count -= drop
        }

        for i in 0..<n {
            storage[writeIndex] = base[srcOffset + i]
            writeIndex = (writeIndex + 1) % capacity
        }
        count += n
    }

    /// Attempts to pop exactly `n` samples. Returns nil if fewer than `n` available.
    func pop(count n: Int) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard count >= n else { return nil }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        count -= n
        return out
    }
}
