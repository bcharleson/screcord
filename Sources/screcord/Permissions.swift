import AVFoundation
import Foundation

enum Permissions {
    static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw ScrecordError.permissionDenied(
                    "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
                )
            }
        case .denied, .restricted:
            throw ScrecordError.permissionDenied(
                "Microphone access is blocked. Enable it in System Settings → Privacy & Security → Microphone."
            )
        @unknown default:
            throw ScrecordError.permissionDenied("Unknown microphone authorization state.")
        }
    }
}
