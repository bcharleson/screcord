import CoreGraphics
import Foundation
import ScreenCaptureKit

enum DisplayResolver {
    /// Main display first, then remaining displays in stable order.
    static func ordered(_ displays: [SCDisplay]) -> [SCDisplay] {
        let mainID = CGMainDisplayID()
        let main = displays.first(where: { $0.displayID == mainID })
        let rest = displays.filter { $0.displayID != mainID }
        if let main {
            return [main] + rest
        }
        return displays
    }
}

enum AudioMode: String, CaseIterable {
    case none
    case system
    case mic
    case both

    var capturesSystemAudio: Bool { self == .system || self == .both }
    var capturesMicrophone: Bool { self == .mic || self == .both }

    static func parse(_ raw: String) throws -> AudioMode {
        guard let mode = AudioMode(rawValue: raw.lowercased()) else {
            throw ScrecordError.invalidAudioMode(raw)
        }
        return mode
    }
}

enum RecordPreset: String, CaseIterable {
    case tutorial
    case broll
    case cleanUI = "clean-ui"
    case motion

    func apply(to options: inout RecordOptions) {
        switch self {
        case .tutorial:
            options.audioMode = .both
            options.showCursor = true
            options.fps = 30
            options.videoBitrate = 10_000_000
            options.countdown = 3
        case .broll:
            options.audioMode = .system
            options.showCursor = false
            options.fps = 30
            options.videoBitrate = 16_000_000
            options.countdown = 0
        case .cleanUI:
            options.audioMode = .system
            options.showCursor = false
            options.fps = 30
            options.videoBitrate = 12_000_000
            options.countdown = 1
        case .motion:
            options.audioMode = .system
            options.showCursor = true
            options.fps = 60
            options.videoBitrate = 20_000_000
            options.countdown = 0
        }
    }

    static func parse(_ raw: String) throws -> RecordPreset {
        guard let preset = RecordPreset(rawValue: raw.lowercased()) else {
            throw ScrecordError.unsupported(
                "Invalid preset '\(raw)'. Use: tutorial, broll, clean-ui, motion"
            )
        }
        return preset
    }
}

struct Region: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    static func parse(_ raw: String) throws -> Region {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let w = Double(parts[2]),
              let h = Double(parts[3]),
              w > 0, h > 0
        else {
            throw ScrecordError.invalidRegion(raw)
        }
        return Region(x: x, y: y, width: w, height: h)
    }
}

struct ChapterMarker: Codable, Sendable {
    var seconds: Double
    var label: String
}

struct RecordOptions {
    /// Display index or name (`main`, substring). Ignored when window/app capture is set.
    var displayQuery: String = "0"
    var region: Region?
    /// Substring or exact window title match.
    var windowQuery: String?
    /// Bundle id or app name substring.
    var appQuery: String?
    var audioMode: AudioMode = .both
    var showCursor: Bool = true
    var highlightClicks: Bool = false
    var fps: Int = 30
    var videoBitrate: Int = 8_000_000
    var audioBitrate: Int = 192_000
    var countdown: Int = 3
    var duration: Double?
    /// Stop after this many seconds of near-silence (requires audio).
    var idleStop: Double?
    /// Optional single-file path. When set, session lives in `<stem>.session/` beside it.
    var outputURL: URL?
    var slug: String?
    var scale: Int = 2
    var excludeSelf: Bool = true
    var meters: Bool?
    var recordWebcam: Bool = false
    var preset: RecordPreset?
    /// Roll a new part file every N minutes. Default 5 — max loss on writer death is one segment.
    /// Set 0 only if you accept single-file risk (`--no-segment`).
    var segmentMinutes: Double = 5
}

/// Snapshot used by the live watchdog so silent writer death is impossible.
struct RecorderHealth: Sendable {
    var isHealthy: Bool
    var isPaused: Bool
    var didStart: Bool
    var timelineSeconds: Double
    var framesAppended: Int
    var fileBytes: Int64
    var secondsSinceLastAppend: Double
    var writerStatus: String
    var failureReason: String?
    var outputPath: String
}

struct StopResult: Sendable {
    var url: URL
    /// Non-nil when the file was salvaged after a writer/finalize failure.
    var salvageWarning: String?
}

struct SessionManifest: Codable {
    var version: Int
    var startedAt: String
    var slug: String?
    var sessionDir: String
    var segmentMinutes: Double
    var parts: [SessionPart]
    var status: String
    var lastHeartbeatAt: String?
    var failureReason: String?
}

struct SessionPart: Codable {
    var index: Int
    var path: String
    var bytes: Int64?
    var closedAt: String?
    var salvage: Bool
}

enum ScrecordError: LocalizedError {
    case noDisplays
    case invalidDisplayIndex(Int, available: Int)
    case invalidAudioMode(String)
    case invalidRegion(String)
    case invalidFPS(Int)
    case permissionDenied(String)
    case writerFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "No displays found. Grant Screen Recording permission and try again."
        case .invalidDisplayIndex(let index, let available):
            return "Display index \(index) is out of range. Available: 0..\(max(0, available - 1))"
        case .invalidAudioMode(let raw):
            return "Invalid audio mode '\(raw)'. Use: none, system, mic, both"
        case .invalidRegion(let raw):
            return "Invalid region '\(raw)'. Use: x,y,width,height (points)"
        case .invalidFPS(let fps):
            return "Invalid fps \(fps). Use an integer from 1 to 60."
        case .permissionDenied(let detail):
            return "Permission denied: \(detail)"
        case .writerFailed(let detail):
            return "Failed to write recording: \(detail)"
        case .unsupported(let detail):
            return detail
        }
    }
}

enum OutputPath {
    static let sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop")
        .appendingPathComponent("screcord-sessions")

    static func cleanSlug(_ slug: String?) -> String {
        guard let slug, !slug.isEmpty else { return "" }
        let cleaned = slug
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Crash-safe session folder. Always used — parts land here, never one fragile file.
    ///
    /// - No `-o`: `~/Desktop/screcord-sessions/<stamp>[-slug]/`
    /// - With `-o foo.mp4`: `foo.session/` beside the requested path
    static func sessionDirectory(options: RecordOptions) -> URL {
        if let output = options.outputURL {
            let parent = output.deletingLastPathComponent()
            let stem = output.deletingPathExtension().lastPathComponent
            return parent.appendingPathComponent("\(stem).session")
        }
        let stamp = timestamp()
        let slug = cleanSlug(options.slug)
        let name = slug.isEmpty ? stamp : "\(stamp)-\(slug)"
        return sessionsRoot.appendingPathComponent(name)
    }

    static func partURL(sessionDir: URL, index: Int) -> URL {
        sessionDir.appendingPathComponent(String(format: "part-%02d.mp4", index))
    }

    static func manifestURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("session.json")
    }

    /// Legacy single-file default (kept for tests/compat). Prefer sessionDirectory.
    static func defaultURL(
        slug: String? = nil,
        on desktop: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
    ) -> URL {
        let stamp = timestamp()
        let cleaned = cleanSlug(slug)
        let slugPart = cleaned.isEmpty ? "" : "-\(cleaned)"
        return desktop.appendingPathComponent("screcord-\(stamp)\(slugPart).mp4")
    }
}
