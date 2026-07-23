import AppKit
import Foundation
import ScreenCaptureKit

struct CapturableWindow: Sendable {
    var index: Int
    var title: String
    var appName: String
    var bundleID: String
    var frame: CGRect
    var windowID: CGWindowID
}

enum WindowCatalog {
    static func list(from content: SCShareableContent, filter: String? = nil) -> [CapturableWindow] {
        let query = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let windows = content.windows
            .filter { ($0.title?.isEmpty == false) }
            .filter { window in
                guard let query, !query.isEmpty else { return true }
                let title = (window.title ?? "").lowercased()
                let app = (window.owningApplication?.applicationName ?? "").lowercased()
                return title.contains(query) || app.contains(query)
            }
            .sorted {
                let a = ($0.owningApplication?.applicationName ?? "", $0.title ?? "")
                let b = ($1.owningApplication?.applicationName ?? "", $1.title ?? "")
                return a < b
            }

        return windows.enumerated().map { index, window in
            CapturableWindow(
                index: index,
                title: window.title ?? "(untitled)",
                appName: window.owningApplication?.applicationName ?? "?",
                bundleID: window.owningApplication?.bundleIdentifier ?? "",
                frame: window.frame,
                windowID: window.windowID
            )
        }
    }

    static func scWindow(matching query: String, in content: SCShareableContent) throws -> SCWindow {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = list(from: content)

        if let index = Int(trimmed) {
            guard index >= 0, index < listed.count else {
                throw ScrecordError.unsupported(
                    "Window index \(index) out of range. Run: screcord windows"
                )
            }
            let target = listed[index]
            guard let match = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw ScrecordError.unsupported("Window \(index) disappeared. Run: screcord windows")
            }
            return match
        }

        let q = trimmed.lowercased()
        let matches = content.windows.filter { window in
            let title = (window.title ?? "").lowercased()
            let app = (window.owningApplication?.applicationName ?? "").lowercased()
            return title.contains(q) || app.contains(q)
        }
        guard let window = matches.first else {
            throw ScrecordError.unsupported("No window matching '\(query)'. Run: screcord windows")
        }
        return window
    }
}

enum WindowIdentifier {
    /// Flash numbered badges over each capturable window.
    static func flash(seconds: Double, filter: String? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = WindowCatalog.list(from: content, filter: filter)
        guard !windows.isEmpty else {
            throw ScrecordError.unsupported("No windows found. Grant Screen Recording permission, then retry.")
        }

        // Cap overlays so we don't cover the desktop with dozens of badges.
        let visible = Array(windows.prefix(24))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)

                var overlays: [NSWindow] = []
                for info in visible {
                    let overlay = makeBadge(info: info)
                    overlay.orderFrontRegardless()
                    overlays.append(overlay)
                }

                print("Look at your windows — flashing indexes for \(formatSeconds(seconds))s:")
                for info in visible {
                    print("  [\(info.index)] \(info.appName) — \(info.title)")
                }
                if windows.count > visible.count {
                    print("  … +\(windows.count - visible.count) more (use: screcord windows --filter \"App\")")
                }
                print("Then run: screcord record --window <index-or-title>")

                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                for overlay in overlays {
                    overlay.orderOut(nil)
                }
                continuation.resume()
            }
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        seconds == floor(seconds) ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    private static func makeBadge(info: CapturableWindow) -> NSWindow {
        // SCWindow.frame is top-left global; Cocoa windows use bottom-left.
        let screenHeight = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let cocoaY = screenHeight - info.frame.origin.y - info.frame.height
        let badgeSize = CGSize(width: min(max(info.frame.width, 160), 360), height: 72)
        let origin = CGPoint(
            x: info.frame.midX - badgeSize.width / 2,
            y: cocoaY + info.frame.height / 2 - badgeSize.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: badgeSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(origin: .zero, size: badgeSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        container.layer?.cornerRadius = 14

        let indexLabel = NSTextField(labelWithString: "[\(info.index)]")
        indexLabel.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        indexLabel.textColor = .white
        indexLabel.alignment = .center
        indexLabel.frame = NSRect(x: 8, y: 28, width: badgeSize.width - 16, height: 34)

        let title = "\(info.appName) — \(info.title)"
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 10, y: 8, width: badgeSize.width - 20, height: 20)

        container.addSubview(indexLabel)
        container.addSubview(titleLabel)
        window.contentView = container
        return window
    }
}
