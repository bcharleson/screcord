import Foundation

struct CLI {
    enum Command {
        case help
        case version
        case devices
        case record(RecordOptions)
    }

    static let version = "1.0.0"

    static func parse(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws -> Command {
        if arguments.isEmpty { return .help }

        var args = arguments
        let head = args.removeFirst()

        switch head {
        case "help", "-h", "--help":
            return .help
        case "version", "-v", "--version":
            return .version
        case "devices", "list":
            return .devices
        case "record":
            return .record(try parseRecordOptions(args))
        default:
            // Allow `screcord [options]` as shorthand for record
            if head.hasPrefix("-") {
                return .record(try parseRecordOptions([head] + args))
            }
            throw ScrecordError.unsupported("Unknown command '\(head)'. Try: screcord help")
        }
    }

    private static func parseRecordOptions(_ args: [String]) throws -> RecordOptions {
        var options = RecordOptions()
        var index = 0

        while index < args.count {
            let arg = args[index]

            func needValue() throws -> String {
                index += 1
                guard index < args.count else {
                    throw ScrecordError.unsupported("Missing value for \(arg)")
                }
                return args[index]
            }

            switch arg {
            case "--display", "-d":
                guard let value = Int(try needValue()) else {
                    throw ScrecordError.unsupported("Invalid --display value")
                }
                options.displayIndex = value
            case "--region", "-r":
                options.region = try Region.parse(try needValue())
            case "--audio", "-a":
                options.audioMode = try AudioMode.parse(try needValue())
            case "--no-cursor":
                options.showCursor = false
            case "--cursor":
                options.showCursor = true
            case "--fps":
                guard let fps = Int(try needValue()), (1...60).contains(fps) else {
                    throw ScrecordError.invalidFPS(Int(args[min(index + 1, args.count - 1)]) ?? -1)
                }
                options.fps = fps
            case "--bitrate", "--video-bitrate":
                guard let rate = Int(try needValue()), rate > 0 else {
                    throw ScrecordError.unsupported("Invalid --bitrate value")
                }
                options.videoBitrate = rate
            case "--audio-bitrate":
                guard let rate = Int(try needValue()), rate > 0 else {
                    throw ScrecordError.unsupported("Invalid --audio-bitrate value")
                }
                options.audioBitrate = rate
            case "--countdown", "-c":
                guard let value = Int(try needValue()), value >= 0 else {
                    throw ScrecordError.unsupported("Invalid --countdown value")
                }
                options.countdown = value
            case "--duration", "-t":
                guard let value = Double(try needValue()), value > 0 else {
                    throw ScrecordError.unsupported("Invalid --duration value")
                }
                options.duration = value
            case "--output", "-o":
                let path = try needValue()
                options.outputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            case "--scale":
                guard let value = Int(try needValue()), (1...3).contains(value) else {
                    throw ScrecordError.unsupported("Invalid --scale value (use 1, 2, or 3)")
                }
                options.scale = value
            case "--help", "-h":
                // Handled by caller if needed; ignore inside record options
                break
            default:
                throw ScrecordError.unsupported("Unknown option '\(arg)'. Try: screcord help")
            }

            index += 1
        }

        return options
    }

    static func printHelp() {
        let text = """
        screcord \(version) — reliable macOS screen recorder (ScreenCaptureKit)

        USAGE:
          screcord devices
          screcord record [options]
          screcord [options]              # same as record

        COMMANDS:
          devices             List displays and microphones
          record              Start a recording
          help                Show this help
          version             Show version

        OPTIONS:
          -d, --display <n>         Display index (default: 0)
          -r, --region x,y,w,h      Capture region in points
          -a, --audio <mode>        none | system | mic | both (default: both)
              --no-cursor           Hide mouse cursor
              --cursor              Show mouse cursor (default)
              --fps <n>             Frame rate 1–60 (default: 30)
              --bitrate <bps>       Video bitrate (default: 8000000)
              --audio-bitrate <bps> AAC bitrate (default: 192000)
          -c, --countdown <sec>     Countdown before start (default: 3)
          -t, --duration <sec>      Auto-stop after N seconds
          -o, --output <path>       Output .mp4 path (default: ~/Desktop/screcord-TIMESTAMP.mp4)
              --scale <1|2|3>       Pixel scale factor (default: 2)

        EXAMPLES:
          screcord devices
          screcord record
          screcord record --audio system --no-cursor
          screcord record --audio mic --countdown 5
          screcord record --region 0,0,1280,720 --fps 60
          screcord record --display 1 --duration 30 -o ~/Movies/demo.mp4

        STOP:
          Press Ctrl+C (or send SIGTERM) to finish and finalize the .mp4.

        PERMISSIONS:
          System Settings → Privacy & Security → Screen & System Audio Recording
          System Settings → Privacy & Security → Microphone  (for mic/both)
          Grant access to your terminal app (Terminal, iTerm, Warp, etc.), then re-run.

        NOTES:
          • Output is H.264 + AAC in an .mp4 container (yuv420p / NV12 source).
          • System audio uses ScreenCaptureKit — no BlackHole or loopback driver.
          • On macOS 15+, microphone is captured natively by ScreenCaptureKit.
          • On macOS 13–14, microphone uses AVFoundation as a fallback track.
        """
        print(text)
    }
}
