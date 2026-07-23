import AVFoundation
import Foundation

enum Permissions {
    static func ensureMicrophoneAccess() async throws {
        try await ensureAccess(for: .audio, label: "Microphone")
    }

    static func ensureCameraAccess() async throws {
        try await ensureAccess(for: .video, label: "Camera")
    }

    private static func ensureAccess(for mediaType: AVMediaType, label: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: mediaType)
            if !granted {
                throw ScrecordError.permissionDenied(
                    "\(label) access was denied. Enable it in System Settings → Privacy & Security → \(label)."
                )
            }
        case .denied, .restricted:
            throw ScrecordError.permissionDenied(
                "\(label) access is blocked. Enable it in System Settings → Privacy & Security → \(label)."
            )
        @unknown default:
            throw ScrecordError.permissionDenied("Unknown \(label.lowercased()) authorization state.")
        }
    }
}
