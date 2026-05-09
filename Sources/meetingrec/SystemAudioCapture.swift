import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures system audio via ScreenCaptureKit. An SCStream with capturesAudio = true
/// delivers CMSampleBuffers containing Float32 PCM (typically 48kHz, stereo). We convert
/// to 16kHz mono and push into the shared ring buffer.
///
/// SCKit has a habit of stopping streams that look "unhealthy" to it — particularly
/// when another SCKit client (Zoom, Chime, Teams, Screen Sharing) starts or reconfigures.
/// To survive that we: (a) use a reasonable video config even though we don't consume
/// video, (b) attach a no-op video output so the pipeline looks normal to the system,
/// and (c) auto-restart the stream when `didStopWithError` fires.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let ringBuffer: FloatRingBuffer
    private let errorHandler: (Error) -> Void
    private var stream: SCStream?
    private var converter: Mono16kConverter?
    private let converterQueue = DispatchQueue(label: "meetingrec.system-audio-converter")
    private let videoQueue = DispatchQueue(label: "meetingrec.system-video-sink")
    private let controlQueue = DispatchQueue(label: "meetingrec.system-audio-control")
    private var shouldBeRunning = false
    private var restartAttempts = 0
    private let maxRestartAttempts = 10

    init(ringBuffer: FloatRingBuffer, errorHandler: @escaping (Error) -> Void) {
        self.ringBuffer = ringBuffer
        self.errorHandler = errorHandler
    }

    func start() async throws {
        shouldBeRunning = true
        try await startStream()
    }

    func stop() async {
        shouldBeRunning = false
        guard let stream = stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            // Non-fatal on shutdown.
        }
        self.stream = nil
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "meetingrec", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No displays available from ScreenCaptureKit."
            ])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Use the display's native pixel dimensions at a low frame rate. A "2x2 at 1fps"
        // config is technically legal but SCKit sometimes treats pathologically tiny
        // sizes as unhealthy. Native dims at 2fps is cheap and stable.
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 2fps
        config.showsCursor = false
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: converterQueue)
        // Attach a video output that just drops every frame. SCKit seems to prefer
        // having a video consumer even when you only care about audio.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
        restartAttempts = 0
    }

    private func scheduleRestart(after error: Error) {
        guard shouldBeRunning else { return }
        restartAttempts += 1
        guard restartAttempts <= maxRestartAttempts else {
            errorHandler(NSError(domain: "meetingrec", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "System audio stream keeps stopping; giving up after \(maxRestartAttempts) restart attempts. Last error: \(error.localizedDescription)"
            ]))
            return
        }
        // Exponential-ish backoff capped at 2s. Gives the other SCKit client (Zoom etc.)
        // a moment to finish whatever it was doing that kicked us.
        let delaySeconds = min(2.0, 0.25 * Double(restartAttempts))
        errorHandler(NSError(domain: "meetingrec", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "System audio stream stopped (\(error.localizedDescription)); restarting in \(String(format: "%.2f", delaySeconds))s (attempt \(restartAttempts)/\(maxRestartAttempts))"
        ]))
        controlQueue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self = self, self.shouldBeRunning else { return }
            self.stream = nil
            Task {
                do {
                    try await self.startStream()
                } catch {
                    self.scheduleRestart(after: error)
                }
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            handleAudio(sampleBuffer)
        }
        // All other types (video, microphone on newer SDKs) are intentional no-ops —
        // we only attach a video output to keep SCKit happy, and ignore its frames.
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        // Build the input AVAudioFormat from the sample buffer's actual stream
        // description — ScreenCaptureKit may deliver interleaved or deinterleaved
        // Float32 depending on macOS version, so we trust the ASBD.
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        var asbd = asbdPtr.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        if converter == nil {
            do {
                converter = try Mono16kConverter(inputFormat: inputFormat)
            } catch {
                errorHandler(error)
                return
            }
        }
        guard let converter = converter else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return
        }
        pcmBuf.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuf.mutableAudioBufferList
        )
        guard status == noErr else {
            errorHandler(NSError(domain: "meetingrec", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "CMSampleBufferCopyPCMDataIntoAudioBufferList failed (status=\(status))"
            ]))
            return
        }

        do {
            let samples = try converter.convert(pcmBuf)
            samples.withUnsafeBufferPointer { ringBuffer.append($0) }
        } catch {
            errorHandler(error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        scheduleRestart(after: error)
    }
}
