import Foundation
import Darwin

struct CLIArgs {
    var outputPath: String?
    var noPostprocess: Bool = false
    var showHelp: Bool = false
}

func parseArgs(_ argv: [String]) -> (CLIArgs, String?) {
    var out = CLIArgs()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "-h", "--help":
            out.showHelp = true
        case "--no-postprocess", "-n":
            out.noPostprocess = true
        case _ where a.hasPrefix("-"):
            return (out, "unknown flag: \(a)")
        default:
            if out.outputPath != nil {
                return (out, "unexpected extra argument: \(a)")
            }
            out.outputPath = a
        }
        i += 1
    }
    return (out, nil)
}

let USAGE = """
Usage: meetingrec [options] [output-path.wav]

Records system audio + microphone to a stereo WAV (mic=L, system=R), then runs
the post-processor (diarized transcript + meeting notes) when you Ctrl-C.

Options:
  -n, --no-postprocess   Skip the post-processor; just save the WAV.
  -h, --help             Show this help and exit.

If output-path.wav is omitted, writes to ~/Recordings/meeting-<timestamp>.wav.
"""

@available(macOS 13.0, *)
func run() async -> Int32 {
    // MARK: CLI parse
    let (cli, parseErr) = parseArgs(CommandLine.arguments)
    if let err = parseErr {
        FileHandle.standardError.write(Data("meetingrec: \(err)\n\n\(USAGE)\n".utf8))
        return 1
    }
    if cli.showHelp {
        print(USAGE)
        return 0
    }

    // MARK: output path
    let outputURL: URL
    if let p = cli.outputPath {
        outputURL = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    } else {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("meetingrec: could not create \(dir.path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "meeting-\(formatter.string(from: Date())).wav"
        outputURL = dir.appendingPathComponent(name)
    }

    // Ensure parent dir exists for an explicitly-provided path.
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    } catch {
        FileHandle.standardError.write(Data("meetingrec: could not create parent directory: \(error.localizedDescription)\n".utf8))
        return 1
    }

    // MARK: permissions
    guard await Permissions.ensureScreenRecording() else { return 2 }
    guard await Permissions.ensureMicrophone() else { return 2 }

    // MARK: wiring
    // 5 seconds of headroom per source @ 16kHz = 80_000 samples. Plenty to absorb
    // bursts without growing memory unbounded.
    let micBuffer = FloatRingBuffer(capacity: 80_000)
    let systemBuffer = FloatRingBuffer(capacity: 80_000)

    let writer: WAVWriter
    do {
        writer = try WAVWriter(url: outputURL, sampleRate: 16_000, channels: 2)
    } catch {
        FileHandle.standardError.write(Data("meetingrec: could not open output file \(outputURL.path): \(error.localizedDescription)\n".utf8))
        return 1
    }

    let runtimeErrorHandler: (Error) -> Void = { err in
        // Runtime errors: log but keep going. Device swaps, transient SCKit hiccups, etc.
        FileHandle.standardError.write(Data("meetingrec: runtime warning: \(err.localizedDescription)\n".utf8))
    }

    let mic = MicCapture(ringBuffer: micBuffer, errorHandler: runtimeErrorHandler)
    let system = SystemAudioCapture(ringBuffer: systemBuffer, errorHandler: runtimeErrorHandler)
    let mixer = StereoMixer(
        micBuffer: micBuffer,
        systemBuffer: systemBuffer,
        writer: writer,
        errorHandler: runtimeErrorHandler
    )

    // MARK: start
    do {
        try mic.start()
    } catch {
        FileHandle.standardError.write(Data("meetingrec: failed to start microphone: \(error.localizedDescription)\n".utf8))
        try? writer.close()
        return 1
    }
    do {
        try await system.start()
    } catch {
        FileHandle.standardError.write(Data("meetingrec: failed to start system audio capture: \(error.localizedDescription)\n".utf8))
        mic.stop()
        try? writer.close()
        return 1
    }
    mixer.start()

    let startDate = Date()
    print("Recording started. Press Ctrl-C to stop.")
    print("Output: \(outputURL.path)")

    // MARK: SIGINT
    // Install a signal handler that flips an atomic flag. The main run loop polls
    // that flag and tears down when set. We disable the default SIGINT behavior
    // so the process doesn't get killed before we can finalize the WAV header.
    let sigintReceived = ManagedAtomicBool()
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        sigintReceived.set(true)
    }
    source.resume()

    // Poll for SIGINT. Using a simple sleep loop here rather than RunLoop.main.run()
    // to keep lifecycle obvious and cancellable.
    while !sigintReceived.get() {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }

    // MARK: shutdown
    print("\nStopping…")
    mic.stop()
    await system.stop()
    mixer.stopAndFlush()

    do {
        try writer.close()
    } catch {
        FileHandle.standardError.write(Data("meetingrec: error finalizing WAV: \(error.localizedDescription)\n".utf8))
        return 1
    }

    let duration = writer.durationSeconds
    let wall = Date().timeIntervalSince(startDate)
    let formattedDuration = String(format: "%.2fs", duration)
    let formattedWall = String(format: "%.2fs", wall)
    print("Saved: \(outputURL.path)")
    print("Duration: \(formattedDuration) (wall clock: \(formattedWall))")

    // MARK: post-processing (diarized transcript + Opus meeting notes)
    //
    // Skip with --no-postprocess (-n). Otherwise we shell out to the
    // `meetingrec-postprocess` Python CLI (installed separately via uv — see
    // postprocess/README.md). We wait for it inline so the user sees the output
    // files land in the same session.
    if !cli.noPostprocess {
        runPostProcessor(wavPath: outputURL)
    }

    return 0
}

/// Invokes `meetingrec-postprocess <wav>`. We look it up in a few places:
///   1. $MEETINGREC_POSTPROCESS (explicit override)
///   2. On $PATH
///   3. A sibling `postprocess/` directory with `uv run meetingrec-postprocess`
///      (dev-mode fallback so `swift run meetingrec` Just Works from the repo)
/// Non-zero exit from the subprocess is surfaced but does NOT fail meetingrec —
/// the WAV is already saved, which is the primary deliverable.
@available(macOS 13.0, *)
func runPostProcessor(wavPath: URL) {
    print("\nRunning post-processor (transcript + meeting notes)…")

    let env = ProcessInfo.processInfo.environment
    let process = Process()
    process.standardInput = FileHandle.nullDevice

    if let explicit = env["MEETINGREC_POSTPROCESS"], !explicit.isEmpty {
        process.executableURL = URL(fileURLWithPath: explicit)
        process.arguments = [wavPath.path]
    } else if let onPath = which("meetingrec-postprocess") {
        process.executableURL = URL(fileURLWithPath: onPath)
        process.arguments = [wavPath.path]
    } else {
        // Dev-mode: try `uv run` in a sibling postprocess/ dir.
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("postprocess", isDirectory: true),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("postprocess", isDirectory: true),
        ]
        guard let repoPP = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pyproject.toml").path) }),
              let uvPath = which("uv") else {
            FileHandle.standardError.write(Data("""
            meetingrec: post-processor not found. Install it once with:
                cd postprocess && uv sync
            and either put `meetingrec-postprocess` on $PATH or set
            $MEETINGREC_POSTPROCESS to its absolute path. Set
            $MEETINGREC_NO_POSTPROCESS=1 to skip this step.

            """.utf8))
            return
        }
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["--project", repoPP.path, "run", "meetingrec-postprocess", wavPath.path]
    }

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            FileHandle.standardError.write(Data("meetingrec: post-processor exited with status \(process.terminationStatus).\n".utf8))
        }
    } catch {
        FileHandle.standardError.write(Data("meetingrec: could not launch post-processor: \(error.localizedDescription)\n".utf8))
    }
}

/// Minimal `which`-in-Swift using the PATH env var.
func which(_ binary: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/" + binary
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Minimal atomic bool to hand between the signal source and the main task.
/// Foundation doesn't ship a native atomic in Swift 5.9 without a dependency,
/// and we only need a one-way flip, so a tiny NSLock wrapper is fine.
final class ManagedAtomicBool {
    private var value = false
    private let lock = NSLock()
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

if #available(macOS 13.0, *) {
    let exitCode = await run()
    exit(exitCode)
} else {
    FileHandle.standardError.write(Data("meetingrec requires macOS 13 or later.\n".utf8))
    exit(1)
}
