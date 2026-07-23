import Foundation

struct CLI {
    enum Command {
        case help
        case version
        case devices
        case windows
        case identify(seconds: Double)
        case record(RecordOptions)
    }

    static let version = "1.2.0"

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
        case "windows":
            return .windows
        case "identify":
            return .identify(seconds: try parseIdentifySeconds(args))
        case "record":
            return .record(try parseRecordOptions(args))
        default:
            if head.hasPrefix("-") {
                return .record(try parseRecordOptions([head] + args))
            }
            throw ScrecordError.unsupported("Unknown command '\(head)'. Try: screcord help")
        }
    }

    private static func parseIdentifySeconds(_ args: [String]) throws -> Double {
        var seconds = 3.0
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--seconds", "-t", "--duration":
                i += 1
                guard i < args.count, let value = Double(args[i]), value > 0 else {
                    throw ScrecordError.unsupported("Invalid identify duration")
                }
                seconds = value
            default:
                if let value = Double(args[i]), value > 0 {
                    seconds = value
                } else {
                    throw ScrecordError.unsupported("Unknown identify option '\(args[i])'")
                }
            }
            i += 1
        }
        return seconds
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
                options.displayQuery = try needValue()
            case "--region", "-r":
                options.region = try Region.parse(try needValue())
            case "--window", "-w":
                options.windowQuery = try needValue()
            case "--app":
                options.appQuery = try needValue()
            case "--audio", "-a":
                options.audioMode = try AudioMode.parse(try needValue())
            case "--preset":
                let preset = try RecordPreset.parse(try needValue())
                options.preset = preset
                preset.apply(to: &options)
            case "--no-cursor":
                options.showCursor = false
            case "--cursor":
                options.showCursor = true
            case "--highlight-clicks":
                options.highlightClicks = true
            case "--fps":
                guard let fps = Int(try needValue()), (1...60).contains(fps) else {
                    throw ScrecordError.invalidFPS(-1)
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
            case "--idle-stop":
                guard let value = Double(try needValue()), value > 0 else {
                    throw ScrecordError.unsupported("Invalid --idle-stop value")
                }
                options.idleStop = value
            case "--output", "-o":
                let path = try needValue()
                options.outputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            case "--slug":
                options.slug = try needValue()
            case "--scale":
                guard let value = Int(try needValue()), (1...3).contains(value) else {
                    throw ScrecordError.unsupported("Invalid --scale value (use 1, 2, or 3)")
                }
                options.scale = value
            case "--exclude-self":
                options.excludeSelf = true
            case "--include-self":
                options.excludeSelf = false
            case "--meters":
                options.meters = true
            case "--no-meters":
                options.meters = false
            case "--webcam":
                options.recordWebcam = true
            case "--headless":
                options.countdown = 0
                options.meters = false
            case "--help", "-h":
                break
            default:
                throw ScrecordError.unsupported("Unknown option '\(arg)'. Try: screcord help")
            }

            index += 1
        }

        return options
    }

    static func printHelp() {
        print(
            """
            screcord \(version) — headless macOS screen recorder for tutorials & YouTube

            USAGE:
              screcord devices | windows | identify [--seconds 3]
              screcord record [options]
              screcord [options]

            COMMANDS:
              devices              List displays + mics (names + placement)
              windows              List capturable windows/apps
              identify             Flash big index badges on each display
              record               Start recording

            PRESETS:
              --preset tutorial    30fps, system+mic, cursor on
              --preset broll       high bitrate, system audio, no cursor
              --preset clean-ui    system audio, no cursor
              --preset motion      60fps silky UI B-roll

            TARGET:
              -d, --display <n|name|main>
              -w, --window <title>           Single window capture
                  --app <name|bundle>        Single app capture
              -r, --region x,y,w,h

            AUDIO / VIDEO:
              -a, --audio none|system|mic|both
                  --meters / --no-meters     Live loudness meters (default: on in TTY)
                  --idle-stop <sec>          Auto-stop after silence
                  --webcam                   Also record companion *-cam.mp4
                  --highlight-clicks         Yellow click ripples (Accessibility)
                  --no-cursor / --cursor
                  --fps --bitrate --audio-bitrate --scale

            SESSION:
              -c, --countdown <sec>
              -t, --duration <sec>
                  --slug <name>              Desktop filename tag
              -o, --output <path>
                  --exclude-self             Hide terminal/screcord (default on)
                  --include-self
                  --headless                 countdown 0, meters off (agents)

            DURING RECORDING (TTY):
              p  pause/resume     m  chapter marker     q / Ctrl+C  stop

            EXAMPLES:
              screcord identify
              screcord record --preset tutorial --slug auth-flow
              screcord record --preset broll --display main --duration 20
              screcord record --window \"Notion\" --audio system --meters
              screcord record --app Safari --preset clean-ui
              screcord record --audio both --idle-stop 90 --slug talking-head
            """
        )
    }
}
