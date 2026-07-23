import Darwin
import Foundation

struct ChapterMarkerEvent: Sendable {
    var seconds: Double
    var label: String
}

/// Non-blocking stdin controls for attended CLI sessions.
final class RecordingControls: @unchecked Sendable {
    private var oldTermios: termios?
    private var source: DispatchSourceRead?
    private let onPauseToggle: () -> Void
    private let onMarker: () -> Void
    private let onQuit: () -> Void
    private(set) var isEnabled = false

    init(onPauseToggle: @escaping () -> Void, onMarker: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onPauseToggle = onPauseToggle
        self.onMarker = onMarker
        self.onQuit = onQuit
    }

    func startIfTTY() {
        guard isatty(STDIN_FILENO) != 0 else { return }

        var current = termios()
        tcgetattr(STDIN_FILENO, &current)
        oldTermios = current
        var raw = current
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.0 = 1 // VMIN
        raw.c_cc.1 = 0 // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readKey()
        }
        source.resume()
        self.source = source
        isEnabled = true

        fputs("Keys: [p]ause  [m]arker  [q]/Ctrl+C stop\n", stderr)
    }

    func stop() {
        source?.cancel()
        source = nil
        if var old = oldTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &old)
            oldTermios = nil
        }
        isEnabled = false
    }

    private func readKey() {
        var byte: UInt8 = 0
        let n = read(STDIN_FILENO, &byte, 1)
        guard n == 1 else { return }
        switch Character(UnicodeScalar(byte)) {
        case "p", "P":
            onPauseToggle()
        case "m", "M":
            onMarker()
        case "q", "Q":
            onQuit()
        default:
            break
        }
    }
}

enum MarkerStore {
    static func writeSidecar(for videoURL: URL, markers: [ChapterMarker]) throws {
        guard !markers.isEmpty else { return }
        let sidecar = videoURL.deletingPathExtension().appendingPathExtension("chapters.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(markers)
        try data.write(to: sidecar, options: .atomic)
        print("Chapters → \(sidecar.path)")
        print("YouTube timestamps:")
        for marker in markers {
            print("  \(formatClock(marker.seconds)) \(marker.label)")
        }
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
