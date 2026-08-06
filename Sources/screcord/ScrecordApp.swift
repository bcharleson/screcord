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
        // Always record into a session folder of sealed part files.
        let sessionDir = OutputPath.sessionDirectory(options: options)
        let session = try SessionStore(
            sessionDir: sessionDir,
            segmentMinutes: options.segmentMinutes,
            slug: options.slug
        )
        let firstPart = session.currentPartURL

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
        if options.segmentMinutes > 0 {
            print("Segments: every \(formatMinutes(options.segmentMinutes)) (crash-safe)")
        } else {
            print("Segments: OFF ⚠ single-file risk")
        }
        print("Session:  \(sessionDir.path)")
        print("Part:     \(firstPart.path)")
        print("")

        if options.countdown > 0 {
            for remaining in stride(from: options.countdown, through: 1, by: -1) {
                print("Starting in \(remaining)…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        let recorder = ScreenRecorder(options: options, outputURL: firstPart, meter: meter)
        try await recorder.start()
        print("Target:   \(recorder.resolvedTargetDescription)")
        print("Size:     \(recorder.outputWidth)x\(recorder.outputHeight)")

        var webcam: WebcamRecorder?
        if options.recordWebcam {
            try await Permissions.ensureCameraAccess()
            let companion = sessionDir.appendingPathComponent("webcam.mp4")
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
        print("Watchdog: fail-loud if writer dies · heartbeat every 5s · parts sealed on roll")

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
            audioEnabled: options.audioMode != .none,
            recorder: recorder,
            session: session,
            segmentMinutes: options.segmentMinutes
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

        let result = try await recorder.stop()
        try session.markPartClosed(url: result.url, salvage: result.salvageWarning != nil)
        if let warning = result.salvageWarning {
            fputs("\n⚠ salvaged current part after writer error: \(warning)\n", stderr)
            fputs("⚠ earlier sealed parts in the session folder are still good.\n", stderr)
            session.markFailed(warning)
        } else {
            session.markCompleted()
        }

        if let webcam, let camURL = try await webcam.stop() {
            print("Webcam saved → \(camURL.path)")
        }

        try MarkerStore.writeSidecar(for: result.url, markers: markers)
        session.printSummary()

        // Probe every sealed part + current.
        let listed = (try? FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: nil
        )) ?? []
        let partFiles = listed
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let toProbe = partFiles.isEmpty ? [result.url] : partFiles
        for part in toProbe {
            await RecordingProbe.printReport(for: part)
        }

        if result.salvageWarning != nil {
            // Non-zero so scripts know, but files are on disk.
            exit(2)
        }
    }

    /// ScreenCaptureKit needs the main run loop serviced while recording.
    private static func waitForStopPumpingRunLoop(
        stopSignal: StopSignal,
        duration: Double?,
        idleStop: Double?,
        meter: AudioMeter,
        audioEnabled: Bool,
        recorder: ScreenRecorder,
        session: SessionStore,
        segmentMinutes: Double
    ) async {
        let startedAt = Date()
        var nextMeterLog = Date().addingTimeInterval(1)
        var nextHeartbeat = Date().addingTimeInterval(5)
        var nextHealthCheck = Date().addingTimeInterval(2)
        var nextSegmentAt: Date? = segmentMinutes > 0
            ? Date().addingTimeInterval(segmentMinutes * 60)
            : nil
        var framesAtLastGrowth = 0
        var bytesAtLastGrowth: Int64 = 0
        var lastGrowthAt = Date()
        var sawFirstFrames = false

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

            // --- Segment roll: seal part-N, open part-N+1 ---
            if let due = nextSegmentAt, Date() >= due, !stopSignal.isStopped {
                do {
                    fputs("\n⏭ sealing segment → rolling new part…\n", stderr)
                    let nextURL = try session.beginNextPart()
                    let closed = try await recorder.rotateSegment(to: nextURL)
                    try session.markPartClosed(url: closed.url, salvage: closed.salvageWarning != nil)
                    if let w = closed.salvageWarning {
                        fputs("⚠ previous part salvaged: \(w)\n", stderr)
                    }
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: closed.url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let mb = Double(bytes) / 1_048_576.0
                    fputs(
                        "✓ sealed \(closed.url.lastPathComponent) (\(String(format: "%.1f", mb)) MB) · now writing \(nextURL.lastPathComponent)\n",
                        stderr
                    )
                    nextSegmentAt = Date().addingTimeInterval(segmentMinutes * 60)
                    framesAtLastGrowth = 0
                    bytesAtLastGrowth = 0
                    lastGrowthAt = Date()
                    sawFirstFrames = false
                } catch {
                    fputs("\n🚨 segment roll failed: \(error.localizedDescription)\n", stderr)
                    stopSignal.requestStop(reason: "segment roll failed")
                    break
                }
            }

            // --- Health watchdog: never sit silent while writer is dead ---
            if Date() >= nextHealthCheck {
                let health = recorder.health()
                session.heartbeat(
                    fileBytes: health.fileBytes,
                    timelineSeconds: health.timelineSeconds,
                    writerOK: health.isHealthy
                )

                if health.didStart, health.framesAppended > 0 {
                    sawFirstFrames = true
                }

                if health.framesAppended > framesAtLastGrowth || health.fileBytes > bytesAtLastGrowth {
                    framesAtLastGrowth = health.framesAppended
                    bytesAtLastGrowth = health.fileBytes
                    lastGrowthAt = Date()
                }

                if !health.isHealthy, sawFirstFrames, !health.isPaused {
                    let reason = health.failureReason ?? "writer unhealthy"
                    fputs("\n🚨 WATCHDOG: \(reason)\n", stderr)
                    fputs("🚨 Aborting NOW — sealed session parts are kept.\n", stderr)
                    session.markFailed(reason)
                    stopSignal.requestStop(reason: "writer failure")
                    break
                }

                // File not growing for too long after frames should flow.
                if sawFirstFrames, !health.isPaused,
                   Date().timeIntervalSince(lastGrowthAt) > 20,
                   Date().timeIntervalSince(startedAt) > 15
                {
                    let reason = "file/frames not growing for 20s (writer may be stuck)"
                    fputs("\n🚨 WATCHDOG: \(reason)\n", stderr)
                    session.markFailed(reason)
                    stopSignal.requestStop(reason: "stall")
                    break
                }

                nextHealthCheck = Date().addingTimeInterval(1.5)
            }

            // --- Live heartbeat so you SEE the take is alive ---
            if Date() >= nextHeartbeat {
                let health = recorder.health()
                let mb = Double(health.fileBytes) / 1_048_576.0
                let clock = formatClock(health.timelineSeconds)
                let totalWall = formatClock(Date().timeIntervalSince(startedAt))
                let status = health.isHealthy ? "OK" : "DEAD"
                fputs(
                    String(
                        format: "♥ %@ wall · part %@ · %.1f MB · frames %d · writer %@ · %@\n",
                        totalWall,
                        clock,
                        mb,
                        health.framesAppended,
                        health.writerStatus,
                        status
                    ),
                    stderr
                )
                nextHeartbeat = Date().addingTimeInterval(5)
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

    private static func formatMinutes(_ minutes: Double) -> String {
        if minutes == Double(Int(minutes)) {
            return "\(Int(minutes))m"
        }
        return String(format: "%.1fm", minutes)
    }

    private static func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
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
