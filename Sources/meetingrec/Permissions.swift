import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum Permissions {
    /// Probe screen-recording permission. Returns true if we can enumerate shareable
    /// content (which requires screen-recording entitlement under macOS 13+). If not
    /// granted, prints guidance and returns false.
    ///
    /// NOTE: There is no direct public API to query screen-recording permission
    /// status; calling SCShareableContent.current will itself trigger the TCC prompt
    /// the first time and throw / return empty content when denied. We rely on this
    /// behavior as a permission check.
    static func ensureScreenRecording() async -> Bool {
        do {
            let content = try await SCShareableContent.current
            if content.displays.isEmpty {
                printScreenRecordingInstructions()
                return false
            }
            return true
        } catch {
            printScreenRecordingInstructions(error: error)
            return false
        }
    }

    /// Request microphone permission, waiting until the user responds.
    static func ensureMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { printMicrophoneInstructions() }
            return granted
        case .denied, .restricted:
            printMicrophoneInstructions()
            return false
        @unknown default:
            printMicrophoneInstructions()
            return false
        }
    }

    private static func printScreenRecordingInstructions(error: Error? = nil) {
        let err = error.map { " (underlying error: \($0.localizedDescription))" } ?? ""
        FileHandle.standardError.write(Data("""
        meetingrec: screen recording permission is not granted\(err).

        To capture system audio, macOS treats this as a screen-recording capability.
        Grant access:
          1. Open System Settings → Privacy & Security → Screen & System Audio Recording
          2. Add the meetingrec binary (or your terminal app, if running via `swift run`)
          3. Toggle it on, then quit and relaunch

        On first run the system prompt may not appear automatically — if you don't see
        it, add the binary manually using the + button in that settings pane.

        """.utf8))
    }

    private static func printMicrophoneInstructions() {
        FileHandle.standardError.write(Data("""
        meetingrec: microphone permission is not granted.

        Grant access:
          1. Open System Settings → Privacy & Security → Microphone
          2. Enable meetingrec (or your terminal app, if running via `swift run`)
          3. Relaunch meetingrec

        """.utf8))
    }
}
