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
            case .record(let options):
                try await runRecording(options)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRecording(_ options: RecordOptions) async throws {
        let outputURL = options.outputURL ?? OutputPath.defaultURL()
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        print("screcord \(CLI.version)")
        print("Display:  \(options.displayIndex)")
        if let region = options.region {
            print("Region:   \(Int(region.x)),\(Int(region.y)) \(Int(region.width))x\(Int(region.height))")
        } else {
            print("Region:   full display")
        }
        print("Audio:    \(options.audioMode.rawValue)")
        print("Cursor:   \(options.showCursor ? "on" : "off")")
        print("FPS:      \(options.fps)")
        print("Output:   \(outputURL.path)")
        print("")

        if options.countdown > 0 {
            for remaining in stride(from: options.countdown, through: 1, by: -1) {
                print("Starting in \(remaining)…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        let recorder = ScreenRecorder(options: options, outputURL: outputURL)
        try await recorder.start()
        print("Recording… press Ctrl+C to stop")

        let stopSignal = StopSignal.shared
        stopSignal.install()

        if let duration = options.duration {
            let nanos = UInt64(duration * 1_000_000_000)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await Task.sleep(nanoseconds: nanos)
                    stopSignal.requestStop(reason: "duration elapsed")
                }
                group.addTask {
                    await stopSignal.wait()
                }
                await group.next()
                group.cancelAll()
            }
        } else {
            await stopSignal.wait()
        }

        if let reason = stopSignal.reason {
            print("\nStopping (\(reason))…")
        } else {
            print("\nStopping…")
        }

        let url = try await recorder.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sizeMB = Double(size) / 1_048_576.0
        print(String(format: "Saved %.2f MB → %@", sizeMB, url.path))
    }
}

/// Process-wide Ctrl+C / SIGTERM bridge for async code.
final class StopSignal: @unchecked Sendable {
    static let shared = StopSignal()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var stopped = false
    private(set) var reason: String?
    private var sources: [DispatchSourceSignal] = []

    func install() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            self?.requestStop(reason: "SIGINT")
        }
        sigint.resume()

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            self?.requestStop(reason: "SIGTERM")
        }
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
