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
    var outputURL: URL?
    var slug: String?
    var scale: Int = 2
    var excludeSelf: Bool = true
    var meters: Bool?
    var recordWebcam: Bool = false
    var preset: RecordPreset?
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
    static func defaultURL(
        slug: String? = nil,
        on desktop: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        let slugPart: String
        if let slug, !slug.isEmpty {
            let cleaned = slug
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            slugPart = cleaned.isEmpty ? "" : "-\(cleaned)"
        } else {
            slugPart = ""
        }
        return desktop.appendingPathComponent("screcord-\(stamp)\(slugPart).mp4")
    }
}
