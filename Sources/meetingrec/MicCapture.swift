import Foundation
import AVFoundation

/// Captures microphone audio via AVAudioEngine's input node, converts to 16kHz mono
/// Float32, and pushes samples into the supplied ring buffer.
///
/// Device-change handling: when the default input device changes mid-recording
/// (Bluetooth connects/disconnects, AirPods pair, USB mic plugged in, sample
/// rate changes), macOS posts AVAudioEngine.configurationChangeNotification.
/// At that point our installed tap is bound to the old format and no longer
/// receives buffers — we need to tear it down, reread the input format, build
/// a fresh converter, reinstall the tap, and restart the engine.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let ringBuffer: FloatRingBuffer
    private var converter: Mono16kConverter?
    private let errorHandler: (Error) -> Void

    // Serialize start/stop/reconfigure so a burst of route-change notifications
    // (common when toggling Bluetooth) can't race us into an inconsistent state.
    private let controlQueue = DispatchQueue(label: "meetingrec.mic-capture.control")
    private var shouldBeRunning = false
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?
    private var lastAnnouncedFormat: String = ""

    init(ringBuffer: FloatRingBuffer, errorHandler: @escaping (Error) -> Void) {
        self.ringBuffer = ringBuffer
        self.errorHandler = errorHandler
    }

    func start() throws {
        try controlQueue.sync {
            shouldBeRunning = true
            try startEngineLocked()
            installConfigObserver()
        }
    }

    func stop() {
        controlQueue.sync {
            shouldBeRunning = false
            removeConfigObserver()
            teardownEngineLocked()
        }
    }

    // MARK: - Private

    /// Must be called on controlQueue. Sets up tap + starts engine with current
    /// default-input format.
    private func startEngineLocked() throws {
        let input = engine.inputNode
        // NOTE: inputFormat(forBus:) returns the device's current native format.
        // On Apple Silicon: built-in mic is typically 48kHz mono; AirPods/BT
        // headsets running HFP/SCO for recording are often 16kHz or 24kHz mono.
        let inputFormat = input.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "meetingrec", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Microphone input format is invalid (sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)). Is a default input device configured?"
            ])
        }

        self.converter = try Mono16kConverter(inputFormat: inputFormat)

        // 4096 frames ~= 85ms @ 48kHz — a reasonable tap buffer size.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }
            do {
                let samples = try converter.convert(buffer)
                samples.withUnsafeBufferPointer { self.ringBuffer.append($0) }
            } catch {
                self.errorHandler(error)
            }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()

        let desc = "\(Int(inputFormat.sampleRate))Hz \(inputFormat.channelCount)ch"
        if desc != lastAnnouncedFormat {
            log("Mic capture running at \(desc)")
            lastAnnouncedFormat = desc
        }
    }

    /// Must be called on controlQueue. Safe to call if engine isn't running.
    private func teardownEngineLocked() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        converter = nil
    }

    /// Subscribe to engine reconfiguration notifications (device changes,
    /// sample-rate changes, etc.) and rebuild the engine on each.
    private func installConfigObserver() {
        // AVAudioEngine posts this whenever the underlying audio graph needs
        // rebuilding — Bluetooth connect/disconnect, device swap, sample-rate
        // change, etc. The notification is posted on an arbitrary thread, so
        // we hop to controlQueue before touching shared state.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.controlQueue.async {
                self?.handleConfigChangeLocked()
            }
        }
    }

    private func removeConfigObserver() {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
    }

    /// Must be called on controlQueue. Tear down the old tap/engine and start
    /// a new one with whatever the new default input is. Logs but does not
    /// crash on failure — the mic channel goes silent but SCStream keeps
    /// capturing system audio, so the recording as a whole continues.
    private func handleConfigChangeLocked() {
        guard shouldBeRunning else { return }
        teardownEngineLocked()
        do {
            try startEngineLocked()
        } catch {
            errorHandler(NSError(domain: "meetingrec", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Mic capture failed to restart after audio device change: \(error.localizedDescription). System audio is still being recorded; the mic channel will be silent until this is resolved."
            ]))
        }
    }

    private func log(_ message: String) {
        // Mirror the warning-channel convention used elsewhere in meetingrec.
        FileHandle.standardError.write(Data("meetingrec: \(message)\n".utf8))
    }
}
