import AVFoundation
import Foundation
import ScreenCaptureKit

enum DeviceLister {
    static func listAll() async throws {
        print("=== Displays ===")
        print("Tip: run `screcord identify` to flash a big index on each screen.")
        print("")

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if content.displays.isEmpty {
            print("  (none — grant Screen Recording permission to your terminal app)")
        } else {
            let infos = DisplayCatalog.infos(from: content.displays)
            for info in infos {
                let mainTag = info.isMain ? " [main/default]" : ""
                print("  [\(info.index)] \(info.name)\(mainTag)")
                print("      \(info.width)x\(info.height) pts · \(info.placement) · origin=(\(info.originX),\(info.originY)) · id=\(info.displayID)")
            }
            if let first = infos.first {
                print("")
                print("Select with:  --display 0  |  --display main  |  --display \"\(first.name)\"")
            }
        }

        print("")
        print("=== Audio ===")
        print("  System audio via ScreenCaptureKit (no BlackHole). Modes: none|system|mic|both")

        print("")
        print("=== Microphones ===")
        let defaultMic = AVCaptureDevice.default(for: .audio)
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        var mics = discovery.devices
        if mics.isEmpty, let defaultMic { mics = [defaultMic] }
        if mics.isEmpty {
            print("  (none found)")
        } else {
            for (index, device) in mics.enumerated() {
                let def = device.uniqueID == defaultMic?.uniqueID ? " [default]" : ""
                print("  [\(index)] \(device.localizedName)\(def)")
            }
        }

        print("")
        print("Permissions: Screen & System Audio Recording + Microphone (if needed) for your terminal app.")
    }

    static func listWindows() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows
            .filter { ($0.title?.isEmpty == false) }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }

        print("=== Windows / Apps ===")
        print("Use: screcord record --window \"Title\"   or   --app \"Safari\"")
        print("")

        if windows.isEmpty {
            print("  (none — grant Screen Recording permission)")
            return
        }

        var seenApps = Set<String>()
        for window in windows.prefix(80) {
            let app = window.owningApplication?.applicationName ?? "?"
            let bundle = window.owningApplication?.bundleIdentifier ?? ""
            let title = window.title ?? "(untitled)"
            print("  • \(app) — \(title)")
            if !bundle.isEmpty { seenApps.insert("\(app)|\(bundle)") }
        }

        print("")
        print("=== Apps (for --app) ===")
        for entry in seenApps.sorted() {
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                print("  • \(parts[0])  (\(parts[1]))")
            }
        }
    }
}
