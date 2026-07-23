import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum DeviceLister {
    static func listAll() async throws {
        print("=== Displays ===")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if content.displays.isEmpty {
            print("  (none — grant Screen Recording permission to Terminal/iTerm in")
            print("   System Settings → Privacy & Security → Screen & System Audio Recording)")
        } else {
            let ordered = DisplayResolver.ordered(content.displays)
            for (index, display) in ordered.enumerated() {
                let mainTag = display.displayID == CGMainDisplayID() ? " [main/default]" : ""
                print(
                    "  [\(index)] id=\(display.displayID)  \(display.width)x\(display.height) pts\(mainTag)"
                )
            }
        }

        print("")
        print("=== Audio (ScreenCaptureKit system capture) ===")
        print("  System audio is captured via ScreenCaptureKit (no BlackHole required).")
        print("  Modes: --audio none|system|mic|both")

        print("")
        print("=== Microphones (AVFoundation) ===")
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
        if mics.isEmpty, let defaultMic {
            mics = [defaultMic]
        }
        if mics.isEmpty {
            print("  (none found)")
        } else {
            for (index, device) in mics.enumerated() {
                let def = device.uniqueID == defaultMic?.uniqueID ? " [default]" : ""
                print("  [\(index)] \(device.localizedName)  (\(device.uniqueID))\(def)")
            }
        }

        print("")
        print("Permissions checklist:")
        print("  • Screen & System Audio Recording → enable for your terminal app")
        print("  • Microphone → enable for your terminal app (if using --audio mic|both)")
    }
}
