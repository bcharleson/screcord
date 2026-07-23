import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: RecordOptions
    private let outputURL: URL

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private let sampleQueue = DispatchQueue(label: "com.screcord.samples")
    private var didStartSession = false
    private var isStopping = false
    private var sessionStartPTS: CMTime = .invalid

    // AVFoundation mic fallback (macOS < 15)
    private var captureSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?
    private var micAnchorPTS: CMTime = .invalid

    init(options: RecordOptions, outputURL: URL) {
        self.options = options
        self.outputURL = outputURL
        super.init()
    }

    func start() async throws {
        if options.audioMode.capturesMicrophone {
            try await Permissions.ensureMicrophoneAccess()
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = DisplayResolver.ordered(content.displays)
        guard !displays.isEmpty else { throw ScrecordError.noDisplays }
        guard options.displayIndex >= 0, options.displayIndex < displays.count else {
            throw ScrecordError.invalidDisplayIndex(options.displayIndex, available: displays.count)
        }

        let display = displays[options.displayIndex]
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = try makeStreamConfiguration(display: display)

        try prepareWriter(width: config.width, height: config.height)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        if options.audioMode.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        if options.audioMode.capturesMicrophone {
            if #available(macOS 15.0, *) {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            } else {
                try startLegacyMicrophoneCapture()
            }
        }

        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws -> URL {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async {
                self.isStopping = true
                continuation.resume()
            }
        }

        stopLegacyMicrophoneCapture()

        if let stream {
            try await stream.stopCapture()
        }
        self.stream = nil

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async {
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.micAudioInput?.markAsFinished()
                continuation.resume()
            }
        }

        guard let writer else {
            throw ScrecordError.writerFailed("Writer was never created.")
        }

        if writer.status == .writing {
            await writer.finishWriting()
        }

        if writer.status == .failed {
            throw ScrecordError.writerFailed(writer.error?.localizedDescription ?? "unknown writer error")
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ScrecordError.writerFailed("Output file was not created. Did any frames arrive?")
        }

        return outputURL
    }

    // MARK: - Configuration

    private func makeStreamConfiguration(display: SCDisplay) throws -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = max(1, options.scale)

        if let region = options.region {
            let rect = region.cgRect
            config.sourceRect = rect
            config.width = max(2, Int(rect.width) * scale)
            config.height = max(2, Int(rect.height) * scale)
        } else {
            let maxWidth = 3840
            let targetWidth = min(display.width * scale, maxWidth)
            let targetHeight = Int(
                (Double(targetWidth) * Double(display.height) / Double(display.width)).rounded()
            )
            config.width = targetWidth
            config.height = max(2, targetHeight)
        }

        config.width = config.width - (config.width % 2)
        config.height = config.height - (config.height % 2)

        let fps = max(1, min(60, options.fps))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.showsCursor = options.showCursor
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = options.audioMode.capturesSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2

        if #available(macOS 15.0, *) {
            config.captureMicrophone = options.audioMode.capturesMicrophone
        }

        return config
    }

    private func prepareWriter(width: Int, height: Int) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScrecordError.writerFailed("Cannot add video input.")
        }
        writer.add(videoInput)
        self.videoInput = videoInput

        if options.audioMode.capturesSystemAudio {
            let input = makeAudioInput()
            guard writer.canAdd(input) else {
                throw ScrecordError.writerFailed("Cannot add system audio input.")
            }
            writer.add(input)
            systemAudioInput = input
        }

        if options.audioMode.capturesMicrophone {
            let input = makeAudioInput()
            guard writer.canAdd(input) else {
                throw ScrecordError.writerFailed("Cannot add microphone audio input.")
            }
            writer.add(input)
            micAudioInput = input
        }

        self.writer = writer
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: options.audioBitrate
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: - Legacy mic (macOS 13/14)

    private func startLegacyMicrophoneCapture() throws {
        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw ScrecordError.unsupported("No default microphone found.")
        }
        let micInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(micInput) else {
            throw ScrecordError.unsupported("Cannot add microphone input.")
        }
        session.addInput(micInput)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            throw ScrecordError.unsupported("Cannot add microphone output.")
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()

        captureSession = session
        micOutput = output
    }

    private func stopLegacyMicrophoneCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        micOutput = nil
    }

    // MARK: - Sample handling

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), !isStopping else { return }

        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer, input: systemAudioInput)
        case .microphone:
            handleAudio(sampleBuffer, input: micAudioInput)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("Stream stopped with error: \(error.localizedDescription)\n".utf8))
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else {
            return
        }

        ensureSessionStarted(with: sampleBuffer)
        guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard didStartSession, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    private func ensureSessionStarted(with sampleBuffer: CMSampleBuffer) {
        guard !didStartSession, let writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startWriting()
        writer.startSession(atSourceTime: pts)
        sessionStartPTS = pts
        didStartSession = true
    }
}

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard didStartSession, !isStopping, let micAudioInput, micAudioInput.isReadyForMoreMediaData else { return }
        guard let retimed = retimedMicBuffer(sampleBuffer, sessionStart: sessionStartPTS) else { return }
        micAudioInput.append(retimed)
    }

    /// Maps AVCapture mic timestamps onto the ScreenCaptureKit writer timeline.
    private func retimedMicBuffer(_ sampleBuffer: CMSampleBuffer, sessionStart: CMTime) -> CMSampleBuffer? {
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if micAnchorPTS == .invalid {
            micAnchorPTS = originalPTS
        }

        let relative = CMTimeSubtract(originalPTS, micAnchorPTS)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMTimeAdd(sessionStart, relative),
            decodeTimeStamp: .invalid
        )

        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr else { return nil }
        return output
    }
}
