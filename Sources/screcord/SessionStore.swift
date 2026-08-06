import Foundation

/// Durable on-disk session: folder of part files + live manifest.
/// Finished parts stay on disk even if later parts die.
final class SessionStore: @unchecked Sendable {
    let sessionDir: URL
    let segmentMinutes: Double
    let slug: String?

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private(set) var parts: [SessionPart] = []
    private(set) var currentPartIndex: Int = 0
    private var status: String = "recording"
    private var failureReason: String?
    private let startedAt: String

    init(sessionDir: URL, segmentMinutes: Double, slug: String?) throws {
        self.sessionDir = sessionDir
        self.segmentMinutes = segmentMinutes
        self.slug = slug
        self.startedAt = ISO8601DateFormatter().string(from: Date())
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        currentPartIndex = 1
        try writeManifest(heartbeat: true)
    }

    var currentPartURL: URL {
        OutputPath.partURL(sessionDir: sessionDir, index: currentPartIndex)
    }

    func markPartClosed(url: URL, salvage: Bool) throws {
        let index = Self.partIndex(from: url) ?? currentPartIndex
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let part = SessionPart(
            index: index,
            path: url.path,
            bytes: bytes,
            closedAt: iso.string(from: Date()),
            salvage: salvage
        )
        if let idx = parts.firstIndex(where: { $0.index == part.index }) {
            parts[idx] = part
        } else {
            parts.append(part)
        }
        // Keep currentPartIndex at least past closed parts.
        if index >= currentPartIndex {
            currentPartIndex = index
        }
        try writeManifest(heartbeat: true)
    }

    func beginNextPart() throws -> URL {
        currentPartIndex += 1
        try writeManifest(heartbeat: true)
        return currentPartURL
    }

    static func partIndex(from url: URL) -> Int? {
        // part-01.mp4 → 1
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("part-") else { return nil }
        return Int(name.dropFirst("part-".count))
    }

    func heartbeat(fileBytes: Int64?, timelineSeconds: Double?, writerOK: Bool) {
        if !writerOK, status == "recording" {
            status = "writer-unhealthy"
        }
        _ = fileBytes
        _ = timelineSeconds
        try? writeManifest(heartbeat: true)
    }

    func markFailed(_ reason: String) {
        status = "failed"
        failureReason = reason
        try? writeManifest(heartbeat: true)
    }

    func markCompleted() {
        status = "completed"
        try? writeManifest(heartbeat: true)
    }

    func printSummary() {
        print("")
        print("=== Session ===")
        print("Dir:      \(sessionDir.path)")
        print("Status:   \(status)")
        if let failureReason {
            print("Failure:  \(failureReason)")
        }
        print("Parts:    \(parts.count) closed (+ current \(currentPartIndex) if open)")
        for part in parts.sorted(by: { $0.index < $1.index }) {
            let mb = Double(part.bytes ?? 0) / 1_048_576.0
            let flag = part.salvage ? " SALVAGED" : ""
            print(String(format: "  part-%02d  %.2f MB%@  %@", part.index, mb, flag, part.path))
        }
        print("Manifest: \(OutputPath.manifestURL(sessionDir: sessionDir).path)")
    }

    private func writeManifest(heartbeat: Bool) throws {
        var openParts = parts
        // Always list the active part path so recovery tools know where to look.
        if !openParts.contains(where: { $0.index == currentPartIndex }) {
            let url = currentPartURL
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            openParts.append(SessionPart(
                index: currentPartIndex,
                path: url.path,
                bytes: bytes,
                closedAt: nil,
                salvage: false
            ))
        }

        let manifest = SessionManifest(
            version: 1,
            startedAt: startedAt,
            slug: slug,
            sessionDir: sessionDir.path,
            segmentMinutes: segmentMinutes,
            parts: openParts.sorted(by: { $0.index < $1.index }),
            status: status,
            lastHeartbeatAt: heartbeat ? iso.string(from: Date()) : nil,
            failureReason: failureReason
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: OutputPath.manifestURL(sessionDir: sessionDir), options: .atomic)
    }
}
