import AVFoundation
import Foundation

enum RecordingProbe {
    static func printReport(for url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let seconds = CMTimeGetSeconds(duration)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let sizeMB = Double(size) / 1_048_576.0

            print("")
            print("=== Probe ===")
            print(String(format: "Duration: %.2fs", seconds))
            print(String(format: "Size:     %.2f MB", sizeMB))

            var hasVideo = false
            var hasAudio = false

            for track in tracks {
                let mediaType = track.mediaType
                if mediaType == .video {
                    hasVideo = true
                    let size = try await track.load(.naturalSize)
                    let fps = try await track.load(.nominalFrameRate)
                    print(String(format: "Video:    %.0fx%.0f @ %.2f fps", abs(size.width), abs(size.height), fps))
                } else if mediaType == .audio {
                    hasAudio = true
                    print("Audio:    track present")
                }
            }

            if !hasVideo {
                print("⚠ No video track — capture may have failed.")
            }
            if !hasAudio {
                print("⚠ No audio track — expected if --audio none.")
            }
            if seconds < 0.4 {
                print("⚠ Very short file — was the recording stopped immediately?")
            }
            print("File:     \(url.path)")
        } catch {
            print("Probe failed: \(error.localizedDescription)")
        }
    }
}
