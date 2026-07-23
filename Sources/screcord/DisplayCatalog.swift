import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct DisplayInfo: Sendable {
    var index: Int
    var displayID: CGDirectDisplayID
    var name: String
    var width: Int
    var height: Int
    var originX: Int
    var originY: Int
    var isMain: Bool
    var placement: String
}

enum DisplayCatalog {
    static func infos(from displays: [SCDisplay]) -> [DisplayInfo] {
        let ordered = DisplayResolver.ordered(displays)
        let mainBounds = CGDisplayBounds(CGMainDisplayID())

        return ordered.enumerated().map { index, display in
            let bounds = CGDisplayBounds(display.displayID)
            return DisplayInfo(
                index: index,
                displayID: display.displayID,
                name: localizedName(for: display.displayID) ?? "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                originX: Int(bounds.origin.x.rounded()),
                originY: Int(bounds.origin.y.rounded()),
                isMain: display.displayID == CGMainDisplayID(),
                placement: placementLabel(for: bounds, main: mainBounds, isMain: display.displayID == CGMainDisplayID())
            )
        }
    }

    static func resolve(_ query: String, in displays: [SCDisplay]) throws -> (index: Int, display: SCDisplay) {
        let ordered = DisplayResolver.ordered(displays)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered == "main" || lowered == "primary" || lowered == "default" {
            guard let display = ordered.first else { throw ScrecordError.noDisplays }
            return (0, display)
        }

        if let index = Int(trimmed) {
            guard index >= 0, index < ordered.count else {
                throw ScrecordError.invalidDisplayIndex(index, available: ordered.count)
            }
            return (index, ordered[index])
        }

        let infos = infos(from: displays)
        let matches = infos.filter { $0.name.lowercased().contains(lowered) }
        if matches.count == 1, let match = matches.first {
            return (match.index, ordered[match.index])
        }
        if matches.isEmpty {
            throw ScrecordError.unsupported(
                "No display matching '\(query)'. Run: screcord devices"
            )
        }
        let listed = matches.map { "[\($0.index)] \($0.name)" }.joined(separator: ", ")
        throw ScrecordError.unsupported(
            "Ambiguous display '\(query)' matched: \(listed). Use an index or a more specific name."
        )
    }

    static func nsScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }
    }

    private static func localizedName(for displayID: CGDirectDisplayID) -> String? {
        nsScreen(for: displayID)?.localizedName
    }

    private static func placementLabel(for bounds: CGRect, main: CGRect, isMain: Bool) -> String {
        if isMain { return "main" }

        let dx = bounds.midX - main.midX
        let dy = bounds.midY - main.midY
        let horizontalGap = bounds.minX >= main.maxX || bounds.maxX <= main.minX
        let verticalGap = bounds.minY >= main.maxY || bounds.maxY <= main.minY

        if horizontalGap && abs(dx) >= abs(dy) {
            return dx > 0 ? "right of main" : "left of main"
        }
        if verticalGap && abs(dy) > abs(dx) {
            // Cocoa coords: larger Y is higher on the desktop arrangement.
            return dy > 0 ? "above main" : "below main"
        }
        if abs(dx) >= abs(dy) {
            return dx > 0 ? "right of main" : "left of main"
        }
        return dy > 0 ? "above main" : "below main"
    }
}
