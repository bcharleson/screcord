import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import QuartzCore
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: RecordOptions
    private let outputURL: URL
    let meter: AudioMeter

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private let sampleQueue = DispatchQueue(label: "com.screcord.samples")
    private var didStartSession = false
    private var isStopping = false
    private var sessionStartPTS: CMTime = .invalid
    private var lastWrittenPTS: CMTime = .invalid

    private var isPaused = false
    private var pauseStartedHost: CFTimeInterval?
    private var pausedSeconds: Double = 0

    private var captureSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?
    private var micAnchorPTS: CMTime = .invalid

    private(set) var resolvedTargetDescription = ""
    private(set) var outputWidth = 0
    private(set) var outputHeight = 0
    private var lastPixelBuffer: CVPixelBuffer?
    private var debugFrameCount = 0
    private var debugCompleteCount = 0
    private var debugAppendCount = 0
    private var debugDropNotReady = 0
    private var debugStatusHistogram: [String: Int] = [:]
    private let debugEnabled = ProcessInfo.processInfo.environment["SCRECORD_DEBUG"] == "1"

    init(options: RecordOptions, outputURL: URL, meter: AudioMeter) {
        self.options = options
        self.outputURL = outputURL
        self.meter = meter
        super.init()
    }

    var isPausedState: Bool {
        sampleQueue.sync { isPaused }
    }

    var timelineSeconds: Double {
        sampleQueue.sync {
            guard sessionStartPTS.isValid, lastWrittenPTS.isValid else { return 0 }
            return CMTimeGetSeconds(CMTimeSubtract(lastWrittenPTS, sessionStartPTS))
        }
    }

    func togglePause() {
        sampleQueue.async {
            if self.isPaused {
                if let start = self.pauseStartedHost {
                    self.pausedSeconds += CACurrentMediaTime() - start
                }
                self.pauseStartedHost = nil
                self.isPaused = false
                fputs("\n▶ resumed\n", stderr)
            } else {
                self.isPaused = true
                self.pauseStartedHost = CACurrentMediaTime()
                fputs("\n⏸ paused (press p to resume)\n", stderr)
            }
        }
    }

    func start() async throws {
        if options.audioMode.capturesMicrophone {
            try await Permissions.ensureMicrophoneAccess()
        }

        // Window capture touches CGS window server APIs; bootstrap AppKit/CG first.
        if options.windowQuery != nil {
            await MainActor.run {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                _ = CGMainDisplayID()
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filterResult = try Self.makeFilter(content: content, options: options)
        resolvedTargetDescription = filterResult.label
        let config = try makeStreamConfiguration(contentSize: filterResult.contentSize)

        try prepareWriter(width: config.width, height: config.height)
        outputWidth = config.width
        outputHeight = config.height

        let stream = SCStream(filter: filterResult.filter, configuration: config, delegate: self)
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
                if self.isPaused, let start = self.pauseStartedHost {
                    self.pausedSeconds += CACurrentMediaTime() - start
                    self.pauseStartedHost = nil
                    self.isPaused = false
                }
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

    // MARK: - Filter

    private struct FilterResult {
        var filter: SCContentFilter
        var contentSize: CGSize
        var label: String
    }

    private static func makeFilter(content: SCShareableContent, options: RecordOptions) throws -> FilterResult {
        let excluded = options.excludeSelf ? excludedApps(from: content) : []

        if let windowQuery = options.windowQuery {
            let window = try WindowCatalog.scWindow(matching: windowQuery, in: content)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = window.frame.size
            let title = window.title ?? "window"
            let app = window.owningApplication?.applicationName ?? "?"
            return FilterResult(filter: filter, contentSize: size, label: "window: \(app) — \(title)")
        }

        if let appQuery = options.appQuery {
            let apps = content.applications.filter {
                $0.applicationName.lowercased().contains(appQuery.lowercased())
                    || $0.bundleIdentifier.lowercased().contains(appQuery.lowercased())
            }
            guard let app = apps.first else {
                throw ScrecordError.unsupported("No app matching '\(appQuery)'. Run: screcord windows")
            }
            let displays = DisplayResolver.ordered(content.displays)
            guard let display = displays.first else { throw ScrecordError.noDisplays }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            return FilterResult(
                filter: filter,
                contentSize: CGSize(width: display.width, height: display.height),
                label: "app: \(app.applicationName)"
            )
        }

        let resolved = try DisplayCatalog.resolve(options.displayQuery, in: content.displays)
        let display = resolved.display
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let info = DisplayCatalog.infos(from: content.displays).first { $0.displayID == display.displayID }
        let name = info?.name ?? "display \(resolved.index)"
        return FilterResult(
            filter: filter,
            contentSize: CGSize(width: display.width, height: display.height),
            label: "display[\(resolved.index)] \(name)"
        )
    }

    private static func excludedApps(from content: SCShareableContent) -> [SCRunningApplication] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let denyNames = ["terminal", "iterm", "warp", "kitty", "alacritty", "ghostty", "code", "cursor"]
        return content.applications.filter { app in
            if app.processID == currentPID { return true }
            let name = app.applicationName.lowercased()
            let bundle = app.bundleIdentifier.lowercased()
            return denyNames.contains { name.contains($0) || bundle.contains($0) }
        }
    }

    // MARK: - Configuration

    private func makeStreamConfiguration(contentSize: CGSize) throws -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = max(1, options.scale)

        if let region = options.region {
            let rect = region.cgRect
            config.sourceRect = rect
            config.width = max(2, Int(rect.width) * scale)
            config.height = max(2, Int(rect.height) * scale)
        } else {
            let maxWidth = 3840
            let targetWidth = min(Int(contentSize.width) * scale, maxWidth)
            let targetHeight = Int(
                (Double(targetWidth) * contentSize.height / max(contentSize.width, 1)).rounded()
            )
            config.width = max(2, targetWidth)
            config.height = max(2, targetHeight)
        }

        config.width -= config.width % 2
        config.height -= config.height % 2

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
        // Fragmented MP4: flush the index every 5s so a crash, kill, or failed
        // finalize loses at most the last fragment instead of the whole take.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ScrecordError.writerFailed("Cannot add video input.") }
        writer.add(videoInput)
        self.videoInput = videoInput
        // Pixel-buffer adaptor + copy avoids ScreenCaptureKit recycling buffers mid-encode.
        self.videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        if options.audioMode.capturesSystemAudio {
            let input = makeAudioInput()
            guard writer.canAdd(input) else { throw ScrecordError.writerFailed("Cannot add system audio input.") }
            writer.add(input)
            systemAudioInput = input
        }

        if options.audioMode.capturesMicrophone {
            let input = makeAudioInput()
            guard writer.canAdd(input) else { throw ScrecordError.writerFailed("Cannot add microphone audio input.") }
            writer.add(input)
            micAudioInput = input
        }

        self.writer = writer
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: options.audioBitrate
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: - Legacy mic

    private func startLegacyMicrophoneCapture() throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw ScrecordError.unsupported("No default microphone found.")
        }
        let micInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(micInput) else { throw ScrecordError.unsupported("Cannot add microphone input.") }
        session.addInput(micInput)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else { throw ScrecordError.unsupported("Cannot add microphone output.") }
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

    // MARK: - Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), !isStopping else { return }

        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            meter.observe(sampleBuffer: sampleBuffer, isMicrophone: false)
            handleAudio(sampleBuffer, input: systemAudioInput)
        case .microphone:
            meter.observe(sampleBuffer: sampleBuffer, isMicrophone: true)
            handleAudio(sampleBuffer, input: micAudioInput)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("Stream stopped with error: \(error.localizedDescription)\n".utf8))
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        debugFrameCount += 1
        guard !isPaused else { return }

        let frameKind = frameKind(for: sampleBuffer)
        debugStatusHistogram[frameKind.label, default: 0] += 1

        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let offset = currentPauseOffsetSeconds()
        let pts = offset > 0.000_5
            ? CMTimeSubtract(originalPTS, CMTime(seconds: offset, preferredTimescale: 600))
            : originalPTS

        if lastWrittenPTS.isValid, CMTimeCompare(pts, lastWrittenPTS) <= 0 {
            return
        }

        switch frameKind {
        case .complete(let imageBuffer):
            debugCompleteCount += 1
            if let cloned = clonePixelBuffer(imageBuffer) {
                lastPixelBuffer = cloned
                append(pixelBuffer: cloned, pts: pts)
            }
        case .idle:
            // Static UI: SCK emits idle without a new surface — repeat last frame.
            if let lastPixelBuffer {
                append(pixelBuffer: lastPixelBuffer, pts: pts)
            }
        case .drop:
            return
        }
    }

    private enum FrameKind {
        case complete(CVPixelBuffer)
        case idle
        case drop

        var label: String {
            switch self {
            case .complete: return "complete"
            case .idle: return "idle"
            case .drop: return "drop"
            }
        }
    }

    private func frameKind(for sampleBuffer: CMSampleBuffer) -> FrameKind {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first
        else {
            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                return .complete(imageBuffer)
            }
            return .drop
        }

        let statusRaw: Int?
        if let value = attachments[.status] as? Int {
            statusRaw = value
        } else if let number = attachments[.status] as? NSNumber {
            statusRaw = number.intValue
        } else {
            statusRaw = nil
        }

        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Prefer any buffer that still has pixels.
            if let statusRaw, let status = SCFrameStatus(rawValue: statusRaw), status != .complete, status != .idle {
                return .drop
            }
            return .complete(imageBuffer)
        }

        if let statusRaw, let status = SCFrameStatus(rawValue: statusRaw), status == .idle {
            return .idle
        }
        // rawValue 1 is idle on current SDKs even when enum bridging is odd.
        if statusRaw == 1 {
            return .idle
        }
        return .drop
    }

    private func append(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        ensureSessionStarted(at: pts)
        guard let videoInput, let videoAdaptor else { return }
        guard videoInput.isReadyForMoreMediaData else {
            debugDropNotReady += 1
            return
        }
        if videoAdaptor.append(pixelBuffer, withPresentationTime: pts) {
            debugAppendCount += 1
            lastWrittenPTS = pts
        } else if debugEnabled, debugFrameCount <= 8 {
            let err = writer?.error?.localizedDescription ?? "nil"
            fputs(
                "debug append fail #\(debugFrameCount) pts=\(CMTimeGetSeconds(pts)) err=\(err)\n",
                stderr
            )
        }
    }

    private func clonePixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        var dst: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(src),
            CVPixelBufferGetHeight(src),
            CVPixelBufferGetPixelFormatType(src),
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(src)
        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(dst, plane)
                else { return nil }
                let height = CVPixelBufferGetHeightOfPlane(src, plane)
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
                let bytes = min(srcStride, dstStride)
                for row in 0..<height {
                    memcpy(dstBase.advanced(by: row * dstStride), srcBase.advanced(by: row * srcStride), bytes)
                }
            }
            return dst
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst)
        else { return nil }
        let height = CVPixelBufferGetHeight(src)
        let srcStride = CVPixelBufferGetBytesPerRow(src)
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        let bytes = min(srcStride, dstStride)
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * dstStride), srcBase.advanced(by: row * srcStride), bytes)
        }
        return dst
    }

    func debugSummary() -> String {
        "frames=\(debugFrameCount) complete=\(debugCompleteCount) appended=\(debugAppendCount) notReady=\(debugDropNotReady) statuses=\(debugStatusHistogram) writer=\(writer?.status.rawValue ?? -1)"
    }

    private func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first
        else {
            debugStatusHistogram["no-attachments", default: 0] += 1
            return true
        }

        let statusRaw: Int?
        if let value = attachments[.status] as? Int {
            statusRaw = value
        } else if let number = attachments[.status] as? NSNumber {
            statusRaw = number.intValue
        } else if let value = attachments[SCStreamFrameInfo.status] as? Int {
            statusRaw = value
        } else {
            statusRaw = nil
        }

        guard let statusRaw else {
            debugStatusHistogram["nil-status", default: 0] += 1
            return true
        }
        guard let status = SCFrameStatus(rawValue: statusRaw) else {
            debugStatusHistogram["unknown-\(statusRaw)", default: 0] += 1
            return statusRaw == 0 // be permissive
        }
        debugStatusHistogram["\(status)", default: 0] += 1
        // `idle` = screen unchanged but buffer still valid — required for static tutorial UIs.
        // Skipping idle produces tiny files whenever nothing is animating.
        switch status {
        case .complete, .idle:
            return CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        default:
            return false
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard !isPaused, didStartSession, let input, input.isReadyForMoreMediaData else { return }
        guard let adjusted = retimed(sampleBuffer) else { return }
        input.append(adjusted)
    }

    private func ensureSessionStarted(at pts: CMTime) {
        guard !didStartSession, let writer else { return }
        writer.startWriting()
        writer.startSession(atSourceTime: pts)
        sessionStartPTS = pts
        didStartSession = true
    }

    private func currentPauseOffsetSeconds() -> Double {
        if let start = pauseStartedHost {
            return pausedSeconds + (CACurrentMediaTime() - start)
        }
        return pausedSeconds
    }

    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let offset = currentPauseOffsetSeconds()
        guard offset > 0.000_5 else { return sampleBuffer }
        let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMTimeSubtract(original, CMTime(seconds: offset, preferredTimescale: 600)),
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

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        meter.observe(sampleBuffer: sampleBuffer, isMicrophone: true)
        guard !isPaused, didStartSession, !isStopping, let micAudioInput, micAudioInput.isReadyForMoreMediaData else { return }
        guard let retimedMic = retimedMicBuffer(sampleBuffer, sessionStart: sessionStartPTS) else { return }
        guard let adjusted = retimed(retimedMic) else { return }
        micAudioInput.append(adjusted)
    }

    private func retimedMicBuffer(_ sampleBuffer: CMSampleBuffer, sessionStart: CMTime) -> CMSampleBuffer? {
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if micAnchorPTS == .invalid { micAnchorPTS = originalPTS }
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
