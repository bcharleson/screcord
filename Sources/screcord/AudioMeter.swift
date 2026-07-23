import CoreMedia
import Darwin
import Foundation

/// Live loudness meter for terminal feedback while recording.
final class AudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var systemPeak: Float = 0
    private var micPeak: Float = 0
    private var systemRMS: Float = 0
    private var micRMS: Float = 0
    private var lastLoudAudio = Date()
    private var timer: DispatchSourceTimer?
    private let enabled: Bool
    private let interactiveTTY: Bool

    init(enabled: Bool) {
        self.enabled = enabled
        self.interactiveTTY = isatty(STDERR_FILENO) != 0
    }

    func start() {
        guard enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
        timer.setEventHandler { [weak self] in
            self?.render()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if enabled, interactiveTTY {
            fputs("\u{1B}[2K\r", stderr)
            fflush(stderr)
        }
    }

    func observe(sampleBuffer: CMSampleBuffer, isMicrophone: Bool) {
        // Always track levels (meters UI may be off; idle-stop still needs RMS).
        guard let level = Self.levels(from: sampleBuffer) else { return }
        lock.lock()
        if isMicrophone {
            micPeak = max(micPeak * 0.85, level.peak)
            micRMS = level.rms
        } else {
            systemPeak = max(systemPeak * 0.85, level.peak)
            systemRMS = level.rms
        }
        if level.rms > 0.02 {
            lastLoudAudio = Date()
        }
        lock.unlock()
    }

    func secondsSinceLoudAudio() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastLoudAudio)
    }

    func snapshotDB() -> (system: Float, mic: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (Self.db(systemRMS), Self.db(micRMS))
    }

    private func render() {
        guard enabled else { return }
        lock.lock()
        let sys = systemRMS
        let mic = micRMS
        let sysPeak = systemPeak
        let micPeak = micPeak
        lock.unlock()

        let sysDB = Self.db(sys)
        let micDB = Self.db(mic)
        let line = String(
            format: "♪ sys:%6.1fdB %@  mic:%6.1fdB %@%@",
            sysDB,
            Self.bar(sysPeak),
            micDB,
            Self.bar(micPeak),
            warning(sysDB: sysDB, micDB: micDB)
        )

        if interactiveTTY {
            fputs("\u{1B}[2K\r\(line)", stderr)
            fflush(stderr)
        }
    }

    /// Periodic newline sample for non-TTY / agent logs.
    func logLineIfNeeded(force: Bool = false) {
        guard enabled, !interactiveTTY || force else { return }
        let (sys, mic) = snapshotDB()
        fputs(String(format: "[meter] sys: %.1fdB  mic: %.1fdB%@\n", sys, mic, warning(sysDB: sys, micDB: mic)), stderr)
    }

    private func warning(sysDB: Float, micDB: Float) -> String {
        if sysDB < -55 && micDB < -55 {
            return "  ⚠ quiet — check audio"
        }
        if micDB > -3 {
            return "  ⚠ mic clipping"
        }
        return ""
    }

    private static func db(_ rms: Float) -> Float {
        let clamped = max(rms, 1.0e-8)
        return 20 * log10(clamped)
    }

    private static func bar(_ peak: Float, width: Int = 12) -> String {
        let normalized = min(1, max(0, peak * 2.2))
        let filled = Int((normalized * Float(width)).rounded())
        return "[" + String(repeating: "#", count: filled) + String(repeating: ".", count: width - filled) + "]"
    }

    private static func levels(from sampleBuffer: CMSampleBuffer) -> (rms: Float, peak: Float)? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length > 0
        else { return nil }

        let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }

        // ScreenCaptureKit typically delivers Float32 non-interleaved or Int16.
        if let asbd, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let count = length / MemoryLayout<Float>.size
            return dataPointer.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                var sum: Float = 0
                var peak: Float = 0
                for i in 0..<count {
                    let v = abs(ptr[i])
                    sum += v * v
                    if v > peak { peak = v }
                }
                let rms = count > 0 ? sqrt(sum / Float(count)) : 0
                return (rms, peak)
            }
        }

        let count = length / MemoryLayout<Int16>.size
        return dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
            var sum: Float = 0
            var peak: Float = 0
            for i in 0..<count {
                let v = abs(Float(ptr[i]) / Float(Int16.max))
                sum += v * v
                if v > peak { peak = v }
            }
            let rms = count > 0 ? sqrt(sum / Float(count)) : 0
            return (rms, peak)
        }
    }
}
