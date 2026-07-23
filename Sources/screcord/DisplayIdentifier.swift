import AppKit
import Foundation
import ScreenCaptureKit

enum DisplayIdentifier {
    /// Flash a large index badge on each display so humans (and agents guiding humans) can map indexes.
    static func flash(seconds: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let infos = DisplayCatalog.infos(from: content.displays)
        guard !infos.isEmpty else { throw ScrecordError.noDisplays }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)

                var windows: [NSWindow] = []
                for info in infos {
                    guard let screen = DisplayCatalog.nsScreen(for: info.displayID) else { continue }
                    let window = makeBadgeWindow(info: info, screen: screen)
                    window.orderFrontRegardless()
                    windows.append(window)
                }

                print("Look at your monitors — flashing display indexes for \(formatSeconds(seconds))s:")
                for info in infos {
                    let tag = info.isMain ? " [main]" : ""
                    print("  [\(info.index)] \(info.name)\(tag) — \(info.placement)")
                }
                print("Then run: screcord record --display <index-or-name>")

                // Keep AppKit alive long enough to paint badges.
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                for window in windows {
                    window.orderOut(nil)
                }
                continuation.resume()
            }
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds == floor(seconds) {
            return String(Int(seconds))
        }
        return String(format: "%.1f", seconds)
    }

    private static func makeBadgeWindow(info: DisplayInfo, screen: NSScreen) -> NSWindow {
        let size = CGSize(width: 420, height: 260)
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 28

        let indexLabel = NSTextField(labelWithString: "[\(info.index)]")
        indexLabel.font = NSFont.systemFont(ofSize: 96, weight: .bold)
        indexLabel.textColor = .white
        indexLabel.alignment = .center
        indexLabel.frame = NSRect(x: 20, y: 110, width: size.width - 40, height: 110)

        let nameLabel = NSTextField(labelWithString: info.name)
        nameLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 24, y: 58, width: size.width - 48, height: 36)

        let meta = "\(info.width)×\(info.height) · \(info.placement)"
        let metaLabel = NSTextField(labelWithString: meta)
        metaLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        metaLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        metaLabel.alignment = .center
        metaLabel.frame = NSRect(x: 24, y: 28, width: size.width - 48, height: 28)

        container.addSubview(indexLabel)
        container.addSubview(nameLabel)
        container.addSubview(metaLabel)
        window.contentView = container
        return window
    }
}
