import Darwin
import Dispatch
import Foundation

@main
enum ScrecordApp {
    static func main() async {
        do {
            let command = try CLI.parse()
            switch command {
            case .help:
                CLI.printHelp()
            case .version:
                print("screcord \(CLI.version)")
            case .devices:
                try await DeviceLister.listAll()
            case .windows(let filter):
                try await DeviceLister.listWindows(filter: filter)
            case .identify(let seconds):
                try await DisplayIdentifier.flash(seconds: seconds)
            case .identifyWindows(let seconds, let filter):
                try await WindowIdentifier.flash(seconds: seconds, filter: filter)
            case .record(let options):
                try await runRecording(options)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRecording(_ options: RecordOptions) async throws {
        let outputURL = options.outputURL ?? OutputPath.defaultURL(slug: options.slug)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let metersEnabled = options.meters ?? (isatty(STDERR_FILENO) != 0)
        let meter = AudioMeter(enabled: metersEnabled)

        print("screcord \(CLI.version)")
        if let preset = options.preset {
            print("Preset:   \(preset.rawValue)")
        }
        print("Audio:    \(options.audioMode.rawValue)")
        print("Cursor:   \(options.showCursor ? "on" : "off")\(options.highlightClicks ? " + click highlights" : "")")
        print("FPS:      \(options.fps)")
        print("Meters:   \(metersEnabled ? "on" : "off")")
        print("Output:   \(outputURL.path)")
        print("")

        if options.countdown > 0 {
            for remaining in stride(from: options.countdown, through: 1, by: -1) {
                print("Starting in \(remaining)…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        let recorder = ScreenRecorder(options: options, outputURL: outputURL, meter: meter)
        try await recorder.start()
        print("Target:   \(recorder.resolvedTargetDescription)")
        print("Size:     \(recorder.outputWidth)x\(recorder.outputHeight)")

        var webcam: WebcamRecorder?
        if options.recordWebcam {
            try await Permissions.ensureCameraAccess()
            let base = outputURL.deletingPathExtension().lastPathComponent
            let companion = outputURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(base)-cam.mp4")
            let cam = WebcamRecorder(outputURL: companion)
            try cam.start()
            webcam = cam
            print("Webcam:   \(companion.path)")
        }

        let clickHighlighter = ClickHighlighter()
        if options.highlightClicks {
            await MainActor.run { clickHighlighter.start() }
        }

        meter.start()
        print("Recording…")

        let stopSignal = StopSignal.shared
        stopSignal.install()

        var markers: [ChapterMarker] = []
        let controls = RecordingControls(
            onPauseToggle: { recorder.togglePause() },
            onMarker: {
                let seconds = recorder.timelineSeconds
                let label = "Marker \(markers.count + 1)"
                markers.append(ChapterMarker(seconds: seconds, label: label))
                fputs(String(format: "\n✎ marker %.1fs — %@\n", seconds, label), stderr)
            },
            onQuit: { stopSignal.requestStop(reason: "quit key") }
        )
        controls.startIfTTY()

        await waitForStopPumpingRunLoop(
            stopSignal: stopSignal,
            duration: options.duration,
            idleStop: options.idleStop,
            meter: meter,
            audioEnabled: options.audioMode != .none
        )

        controls.stop()
        meter.stop()
        clickHighlighter.stop()

        if let reason = stopSignal.reason {
            print("\nStopping (\(reason))…")
        } else {
            print("\nStopping…")
        }

        if ProcessInfo.processInfo.environment["SCRECORD_DEBUG"] == "1" {
            fputs("debug: \(recorder.debugSummary())\n", stderr)
        }

        let url = try await recorder.stop()
        if let webcam, let camURL = try await webcam.stop() {
            print("Webcam saved → \(camURL.path)")
        }

        try MarkerStore.writeSidecar(for: url, markers: markers)
        await RecordingProbe.printReport(for: url)
    }

    /// ScreenCaptureKit needs the main run loop serviced while recording.
    private static func waitForStopPumpingRunLoop(
        stopSignal: StopSignal,
        duration: Double?,
        idleStop: Double?,
        meter: AudioMeter,
        audioEnabled: Bool
    ) async {
        let startedAt = Date()
        var nextMeterLog = Date().addingTimeInterval(1)

        while !stopSignal.isStopped {
            if let duration, Date().timeIntervalSince(startedAt) >= duration {
                stopSignal.requestStop(reason: "duration elapsed")
                break
            }

            if let idleStop, audioEnabled, Date().timeIntervalSince(startedAt) > 5 {
                if meter.secondsSinceLoudAudio() >= idleStop {
                    stopSignal.requestStop(reason: "idle silence")
                    break
                }
            }

            if Date() >= nextMeterLog {
                meter.logLineIfNeeded()
                nextMeterLog = Date().addingTimeInterval(1)
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    continuation.resume()
                }
            }
        }
    }
}

final class StopSignal: @unchecked Sendable {
    static let shared = StopSignal()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var stopped = false
    private(set) var reason: String?
    private var sources: [DispatchSourceSignal] = []

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func install() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in self?.requestStop(reason: "SIGINT") }
        sigint.resume()

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in self?.requestStop(reason: "SIGTERM") }
        sigterm.resume()

        sources = [sigint, sigterm]
    }

    func requestStop(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        self.reason = reason
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if stopped {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}
