import Foundation

/// Streaming int16 stereo WAV writer. Writes a placeholder 44-byte header up front,
/// appends interleaved int16 samples as they arrive, and fixes up the RIFF/data size
/// fields on close so the file is valid even for long recordings.
final class WAVWriter {
    private let handle: FileHandle
    private let url: URL
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 16
    private var dataBytesWritten: UInt32 = 0
    private var closed = false

    init(url: URL, sampleRate: UInt32, channels: UInt16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        // Create (or truncate) the file, then open for read/write so we can seek
        // back and overwrite the header on close.
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        self.handle = try FileHandle(forUpdating: url)

        // Write a 44-byte placeholder header; sizes get patched in close().
        let placeholder = Data(count: 44)
        try handle.write(contentsOf: placeholder)
    }

    /// Appends an array of interleaved int16 samples (channel-major order already applied
    /// by the caller — for stereo that means L, R, L, R, ...).
    func append(interleavedInt16: [Int16]) throws {
        guard !closed else { return }
        let byteCount = interleavedInt16.count * MemoryLayout<Int16>.size
        let data = interleavedInt16.withUnsafeBufferPointer { buf -> Data in
            guard let base = buf.baseAddress else { return Data() }
            return Data(bytes: base, count: byteCount)
        }
        try handle.write(contentsOf: data)
        dataBytesWritten &+= UInt32(byteCount)
    }

    /// Patches the header with the final sizes and closes the file.
    func close() throws {
        guard !closed else { return }
        closed = true

        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = dataBytesWritten
        // RIFF size = file size - 8 (for "RIFF" + size field itself).
        // File size = 44 (header) + dataSize, so RIFF size = 36 + dataSize.
        let riffSize: UInt32 = 36 &+ dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.appendLE(uint32: riffSize)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.appendLE(uint32: 16)                 // PCM fmt chunk size
        header.appendLE(uint16: 1)                  // audio format = PCM
        header.appendLE(uint16: channels)
        header.appendLE(uint32: sampleRate)
        header.appendLE(uint32: byteRate)
        header.appendLE(uint16: blockAlign)
        header.appendLE(uint16: bitsPerSample)
        header.append("data".data(using: .ascii)!)
        header.appendLE(uint32: dataSize)

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.synchronize()
        try handle.close()
    }

    var durationSeconds: Double {
        let bytesPerFrame = Double(channels) * Double(bitsPerSample / 8)
        let frames = Double(dataBytesWritten) / bytesPerFrame
        return frames / Double(sampleRate)
    }
}

private extension Data {
    mutating func appendLE(uint16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(uint32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
