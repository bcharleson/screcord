import AVFoundation
import Foundation

/// Parallel webcam capture as a companion MP4 (editors can PIP in post). Keeps screcord headless.
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let outputURL: URL
    private var session: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.screcord.webcam")
    private var started = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw ScrecordError.unsupported("No webcam found for --webcam.")
        }
        let camInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(camInput) else {
            throw ScrecordError.unsupported("Cannot open webcam input.")
        }
        session.addInput(camInput)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw ScrecordError.unsupported("Cannot add webcam output.")
        }
        session.addOutput(output)
        session.commitConfiguration()

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Fragmented MP4: crash-safe incremental index (see ScreenRecorder).
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScrecordError.writerFailed("Cannot add webcam writer input.")
        }
        writer.add(videoInput)

        self.session = session
        self.writer = writer
        self.input = videoInput
        session.startRunning()
    }

    func stop() async throws -> URL? {
        session?.stopRunning()
        session = nil

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.input?.markAsFinished()
                cont.resume()
            }
        }

        guard let writer else { return nil }
        if writer.status == .writing {
            await writer.finishWriting()
        }
        if writer.status == .failed {
            throw ScrecordError.writerFailed(writer.error?.localizedDescription ?? "webcam writer failed")
        }
        return FileManager.default.fileExists(atPath: outputURL.path) ? outputURL : nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let input, input.isReadyForMoreMediaData else { return }
        if !started, let writer {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            started = true
        }
        input.append(sampleBuffer)
    }
}
