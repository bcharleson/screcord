import AppKit
import CoreGraphics
import Foundation

/// Brief click ripples for tutorial emphasis (CLI overlay, no menubar app).
final class ClickHighlighter: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var windows: [NSWindow] = []

    func start() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .leftMouseDown, let refcon else { return Unmanaged.passUnretained(event) }
            let highlighter = Unmanaged<ClickHighlighter>.fromOpaque(refcon).takeUnretainedValue()
            let location = event.location
            DispatchQueue.main.async {
                highlighter.flash(at: location)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs("warning: click highlight requires Accessibility permission (event tap failed)\n", stderr)
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func flash(at point: CGPoint) {
        // CGEvent uses top-left global coords on modern macOS for event.location in some contexts;
        // convert via NSEvent for screen placement.
        let screenPoint = NSPoint(x: point.x, y: point.y)
        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        // Convert from CG top-left style if needed: NSEvent.mouseLocation is bottom-left Cocoa.
        let cocoaPoint = NSEvent.mouseLocation
        let size: CGFloat = 72
        let rect = NSRect(
            x: cocoaPoint.x - size / 2,
            y: cocoaPoint.y - size / 2,
            width: size,
            height: size
        )

        let window = NSWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false

        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        view.layer?.cornerRadius = size / 2
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.systemYellow.cgColor
        window.contentView = view
        window.orderFrontRegardless()
        windows.append(window)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            view.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            window?.orderOut(nil)
            self?.windows.removeAll { $0 === window }
        }
    }
}
