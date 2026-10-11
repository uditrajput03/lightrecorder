//
//  CaptureEngine.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import OSLog

/// Delegate protocol for receiving capture events (non-sample buffer events)
@MainActor
protocol CaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CaptureEngine, didUpdateFilter filter: SCContentFilter)
    func captureEngine(_ engine: CaptureEngine, didStopWithError error: Error?)
    func captureEngine(_ engine: CaptureEngine, systemAudioDidFailWith error: Error?)
    func captureEngineDidCancelPicker(_ engine: CaptureEngine)
}

/// Protocol for receiving sample buffers - called synchronously on capture queue
protocol CaptureEngineSampleBufferDelegate: AnyObject, Sendable {
    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer)
    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)
    nonisolated func captureEngine(_ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer)
}

/// Service responsible for managing ScreenCaptureKit capture streams
@MainActor
final class CaptureEngine: NSObject {

    // MARK: - Properties

    weak var delegate: CaptureEngineDelegate?

    private final class SampleBufferDelegateBox: @unchecked Sendable {
        weak var delegate: CaptureEngineSampleBufferDelegate?
    }
    private let delegateBox = SampleBufferDelegateBox()

    var sampleBufferDelegate: CaptureEngineSampleBufferDelegate? {
        get { delegateBox.delegate }
        set { delegateBox.delegate = newValue }
    }

    private(set) var contentFilter: SCContentFilter?
    private(set) var isCapturing = false

    private var stream: SCStream?
    private let systemAudioStream = SystemAudioStream()
    private let microphoneSession = MicrophoneCaptureSession()
    private let contentFilterService = ContentFilterService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder", category: "CaptureEngine")

    // Queues for sample buffer handling
    private let videoSampleQueue = DispatchQueue(label: "com.lightrecorder.videoSampleQueue", qos: .userInteractive)
    private let audioSampleQueue = DispatchQueue(label: "com.lightrecorder.audioSampleQueue", qos: .userInteractive)
    private let microphoneSampleQueue = DispatchQueue(label: "com.lightrecorder.microphoneSampleQueue", qos: .userInteractive)

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Stream Management

    /// Starts capturing with the current content filter
    /// - Parameters:
    ///   - settings: The settings store containing capture configuration
    ///   - videoSize: The dimensions for the captured video
    ///   - sourceRect: Optional rectangle for area selection (display points, top-left origin)
    func startCapture(with settings: SettingsStore, videoSize: CGSize, sourceRect: CGRect? = nil) async throws {
        guard let filter = contentFilter else {
            throw CaptureError.noContentFilterSelected
        }

        try await verifyPermissions(for: settings)

        // A display selected before it was disconnected still yields a usable filter, but the
        // stream never delivers frames. Fail fast instead of recording without a video track.
        guard await contentFilterService.isSelectedDisplayConnected(filter) else {
            throw CaptureError.selectedDisplayDisconnected
        }

        // Apply content filter settings (wallpaper, dock, menu bar)
        logger.info("Applying content filter settings...")
        let filteredContent = try await contentFilterService.applySettings(to: filter, settings: settings)
        logger.info("Content filter applied, creating stream...")

        // A stream's audio is scoped by its video filter, so a window or application capture
        // would only record the selected app's audio. Those styles get a dedicated
        // full-display audio stream instead; display captures already hear everything.
        let captureStyle = CaptureFilterStyle(filteredContent)
        let needsDedicatedAudioStream = settings.captureSystemAudio && captureStyle != .display

        let streamConfig = createStreamConfiguration(
            from: settings,
            contentSize: videoSize,
            sourceRect: sourceRect,
            isWindowCapture: captureStyle == .window,
            capturesAudio: settings.captureSystemAudio && !needsDedicatedAudioStream
        )

        stream = SCStream(filter: filteredContent, configuration: streamConfig, delegate: self)

        guard let stream else {
            throw CaptureError.failedToCreateStream
        }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleQueue)
        logger.info("Added screen output")

        if settings.captureSystemAudio && !needsDedicatedAudioStream {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleQueue)
            logger.info("Added system audio output")
        }

        if settings.captureMicrophone {
            let box = self.delegateBox
            try await microphoneSession.start(deviceID: settings.selectedMicrophoneID) { [weak self] sampleBuffer in
                guard let self else { return }
                box.delegate?.captureEngine(self, didOutputMicrophoneSampleBuffer: sampleBuffer)
            }
            logger.info("Started AVCaptureSession microphone capture")
        }

        logger.info("Stream config - capturesAudio: \(settings.captureSystemAudio), captureMicrophone: \(settings.captureMicrophone)")
        logger.info("Starting stream capture...")
        if needsDedicatedAudioStream {
            async let audioTask: Void = startSystemAudioStream()
            try await stream.startCapture()
            _ = await audioTask
        } else {
            try await stream.startCapture()
        }
        logger.info("Stream capture started successfully")
        isCapturing = true

        logger.info("Capture started successfully")
    }

    /// Ensures the permissions the requested capture needs are granted, prompting if they are not
    /// - Parameter settings: The settings store containing capture configuration
    private func verifyPermissions(for settings: SettingsStore) async throws {
        let hasPermission = contentFilterService.hasScreenRecordingPermission()
        logger.info("Screen recording permission check: \(hasPermission)")

        guard hasPermission else {
            // Request permission - this will open the system prompt or System Settings
            contentFilterService.requestScreenRecordingPermission()
            throw CaptureError.screenRecordingPermissionDenied
        }

        guard settings.captureMicrophone else { return }

        let hasMicPermission = contentFilterService.hasMicrophonePermission()
        logger.info("Microphone permission check: \(hasMicPermission)")

        if !hasMicPermission, await !contentFilterService.requestMicrophonePermission() {
            throw CaptureError.microphonePermissionDenied
        }
    }

    /// Starts the dedicated system audio stream, keeping the recording alive if it fails
    private func startSystemAudioStream() async {
        do {
            try await systemAudioStream.start(output: self, delegate: self, sampleQueue: audioSampleQueue)
        } catch {
            logger.error("Failed to start system audio stream: \(error.localizedDescription)")
            delegate?.captureEngine(self, systemAudioDidFailWith: error)
        }
    }

    /// Stops the current capture stream
    func stopCapture() async throws {
        await systemAudioStream.stop()
        await microphoneSession.stop()

        guard let runningStream = stream, isCapturing else { return }

        // Detach before suspending, so a second caller cannot stop the same stream again
        stream = nil
        isCapturing = false

        do {
            try await runningStream.stopCapture()
        } catch let error as NSError where error.code == SCStreamError.Code.attemptToStopStreamState.rawValue {
            // The stream had already stopped on its own, which is what was wanted
            logger.debug("Stream was already stopped")
        }

        logger.info("Capture stopped successfully")
    }

    /// Updates the content filter for an active stream
    func updateFilter(_ filter: SCContentFilter) async throws {
        contentFilter = filter

        if let stream, isCapturing {
            try await stream.updateContentFilter(filter)
            logger.info("Content filter updated")
        }
    }

    // MARK: - Configuration

    /// Creates an SCStreamConfiguration from user settings
    /// - Parameters:
    ///   - settings: The settings store containing capture configuration
    ///   - contentSize: The output dimensions for the captured video
    ///   - sourceRect: Optional rectangle for area selection (display points, top-left origin)
    ///   - isWindowCapture: Whether the filter captures a single window
    ///   - capturesAudio: Whether this stream carries system audio, or a dedicated one does
    private func createStreamConfiguration(
        from settings: SettingsStore,
        contentSize: CGSize,
        sourceRect: CGRect? = nil,
        isWindowCapture: Bool = false,
        capturesAudio: Bool = false
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        // Standard 8-bit SDR pixel format (matches default screen recorders like Windows Snipping Tool)
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Set output dimensions - required for proper capture
        config.width = Int(contentSize.width)
        config.height = Int(contentSize.height)

        if isWindowCapture {
            config.scalesToFit = true
        }

        // Set source rect for area selection (only works with display captures)
        if let sourceRect {
            config.sourceRect = sourceRect
            logger.info("Source rect set: \(sourceRect.origin.x),\(sourceRect.origin.y) \(sourceRect.width)x\(sourceRect.height)")
        }

        // Frame rate. `effectiveFrameRate` resolves `.native` to 60.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate.effectiveFrameRate))
        config.queueDepth = 8
        config.showsCursor = settings.showCursor

        // System audio settings
        config.capturesAudio = capturesAudio
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        return config
    }

    /// Clears the current content filter selection
    func clearSelection() {
        contentFilter = nil
    }

    /// Presents the system content sharing picker
    func presentPicker() {
        logger.info("Content sharing picker not available on this macOS SDK")
    }

    /// Deactivates the content sharing picker to remove camera indicator
    func deactivatePicker() {
        logger.info("Picker deactivated")
    }
}

// MARK: - SCStreamDelegate

extension CaptureEngine: SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Resolve the identity here: SCStream is not Sendable and cannot cross to the main actor.
        let isSystemAudioStream = systemAudioStream.owns(stream)

        Task { @MainActor in
            guard !isSystemAudioStream else {
                // Losing system audio must not tear down the video recording
                self.systemAudioStream.handleStoppedExternally()
                self.delegate?.captureEngine(self, systemAudioDidFailWith: error)
                logger.error("System audio stream stopped with error: \(error.localizedDescription)")
                return
            }

            self.isCapturing = false
            self.stream = nil
            await self.microphoneSession.stop()
            await self.systemAudioStream.stop()
            self.delegate?.captureEngine(self, didStopWithError: error)
            logger.error("Stream stopped with error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        // Call sample buffer delegate synchronously on the capture queue
        // to ensure the buffer remains valid during processing
        switch type {
        case .screen:
            delegateBox.delegate?.captureEngine(self, didOutputVideoSampleBuffer: sampleBuffer)
        case .audio:
            delegateBox.delegate?.captureEngine(self, didOutputAudioSampleBuffer: sampleBuffer)
        @unknown default:
            break
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError, Equatable {
    case noContentFilterSelected
    case failedToCreateStream
    case captureAlreadyRunning
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case selectedDisplayDisconnected

    var errorDescription: String? {
        switch self {
        case .noContentFilterSelected:
            return "No content has been selected for capture. Please use the picker to select a window or display."
        case .failedToCreateStream:
            return "Failed to create the capture stream."
        case .captureAlreadyRunning:
            return "A capture session is already in progress."
        case .screenRecordingPermissionDenied:
            return "Screen recording permission is required. Please grant permission in System Settings → Privacy & Security → Screen Recording."
        case .microphonePermissionDenied:
            return "Microphone permission is required. Please grant permission in System Settings → Privacy & Security → Microphone."
        case .selectedDisplayDisconnected:
            return "The selected display is no longer connected. Please select the content to capture again."
        }
    }
}
