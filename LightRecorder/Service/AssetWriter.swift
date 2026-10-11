//
//  AssetWriter.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import AVFoundation
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit
import VideoToolbox
import os

/// Service responsible for writing captured media to disk using AVAssetWriter.
///
/// Designed for lightweight, hardware-accelerated direct encoding similar to
/// default Windows Screen Recorder (Windows Media Foundation / Snipping Tool):
/// - Passes ScreenCaptureKit's native CVPixelBuffers directly into the hardware encoder.
/// - Uses variable frame rate (VFR) timestamps; static screens produce no duplicate frames,
///   saving CPU, GPU, and disk space.
/// - Anchors audio and video to a shared zero-origin without synthetic frame insertion.
final class AssetWriter: CaptureEngineSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?

    private(set) var isWriting = false
    private(set) var outputURL: URL?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder", category: "AssetWriter")

    // Track if we've received the first sample
    private var hasStartedSession = false

    /// Presentation timestamp of the first sample received on any track.
    ///
    /// Every track is rebased against this anchor so the file starts at zero
    /// regardless of which track ScreenCaptureKit delivers first.
    private var sessionAnchor: CMTime = .invalid

    /// Timestamp of the last video frame written, relative to `sessionAnchor`.
    private var lastVideoTime: CMTime = .invalid

    /// Timestamp of the last audio sample written, relative to `sessionAnchor`.
    private var lastAudioTime: CMTime = .invalid

    /// Whether the head of each audio track has already been padded with silence.
    private var hasPaddedAudio = false
    private var hasPaddedMicrophone = false

    private var hasLoggedFirstFrame = false
    private var frameCount = 0

    /// Lock for thread-safe access to writer state
    private let lock = OSAllocatedUnfairLock()

    // MARK: - Setup

    /// Prepares the asset writer for recording
    /// - Parameters:
    ///   - url: The output file URL
    ///   - settings: The settings store containing encoding configuration
    ///   - videoSize: The dimensions of the video
    @MainActor
    func setup(url: URL, settings: SettingsStore, videoSize: CGSize) throws {
        // Ensure output directory exists
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }

        // Create asset writer
        let fileType = settings.containerFormat == .mov ? AVFileType.mov : AVFileType.mp4
        assetWriter = try AVAssetWriter(outputURL: url, fileType: fileType)

        guard let assetWriter else {
            throw AssetWriterError.failedToCreateWriter
        }

        // Configure fragmented writing if crash resilience is enabled
        if settings.crashResilientRecording {
            assetWriter.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 60000)
        }

        // Configure video input
        let videoSettings = AssetWriterSettings.video(from: settings, size: videoSize)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true
        // 60000 time scale evenly represents standard 24, 30, and 60 fps timebases
        videoInput?.mediaTimeScale = 60000

        if let videoInput, assetWriter.canAdd(videoInput) {
            assetWriter.add(videoInput)

            // Create pixel buffer adaptor for appending raw SDR pixel buffers (32BGRA) from ScreenCaptureKit.
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height)
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
        }

        // Configure audio input for system audio
        if settings.captureSystemAudio {
            let audioSettings = AssetWriterSettings.audio(from: settings)
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true

            if let audioInput, assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
            }
        }

        // Configure microphone input as separate track
        if settings.captureMicrophone {
            let micSettings = AssetWriterSettings.audio(from: settings)
            microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            microphoneInput?.expectsMediaDataInRealTime = true

            if let microphoneInput, assetWriter.canAdd(microphoneInput) {
                assetWriter.add(microphoneInput)
            }
        }

        outputURL = url
        resetTimingState()
        frameCount = 0

        logger.info("AssetWriter configured for output: \(url.lastPathComponent)")
    }

    // MARK: - Writing

    /// Starts the writing session
    func startWriting() throws {
        guard let assetWriter, assetWriter.status == .unknown else {
            throw AssetWriterError.writerNotReady
        }

        guard assetWriter.startWriting() else {
            throw AssetWriterError.failedToStartWriting(assetWriter.error)
        }

        isWriting = true
        logger.info("AssetWriter started writing")
    }

    /// Appends a video sample buffer directly to the encoder without synthetic frame duplication.
    ///
    /// Matches Windows screen recorder behavior: only encodes frames when ScreenCaptureKit delivers
    /// an updated frame, leaving the hardware encoder idle during static screen content.
    func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        // Check frame status first - only process complete frames
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[String: Any]],
            let attachments = attachmentsArray.first,
            let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue),
            status == .complete
        else {
            return
        }

        lock.withLockUnchecked {
            guard let assetWriter, assetWriter.status == .writing,
                  let videoInput, let adaptor = pixelBufferAdaptor,
                  videoInput.isReadyForMoreMediaData
            else { return }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startSessionIfNeeded(at: presentationTime)

            // Rebase presentation timestamp against session anchor so track starts at zero
            var rebasedTime = CMTimeSubtract(presentationTime, sessionAnchor)
            if rebasedTime < .zero {
                rebasedTime = .zero
            }

            // Ensure strictly monotonic timestamps required by AVAssetWriter.
            // Drop duplicate or out-of-order timestamps resulting from capture jitter.
            if lastVideoTime.isNumeric && rebasedTime <= lastVideoTime {
                return
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                logger.warning("No image buffer in complete video frame")
                return
            }

            if !hasLoggedFirstFrame {
                hasLoggedFirstFrame = true
                AssetWriterSettings.logPixelBufferProperties(pixelBuffer)
            }

            if adaptor.append(pixelBuffer, withPresentationTime: rebasedTime) {
                lastVideoTime = rebasedTime
                frameCount += 1
            } else {
                logger.error("Failed to append video pixel buffer: \(assetWriter.error?.localizedDescription ?? "no error")")
            }
        }
    }

    /// Appends a system audio sample buffer - called synchronously from capture queue
    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard let assetWriter,
                assetWriter.status == .writing,
                let audioInput,
                audioInput.isReadyForMoreMediaData
            else {
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startSessionIfNeeded(at: pts)

            if !hasPaddedAudio {
                hasPaddedAudio = true
                padWithSilence(sampleBuffer, into: audioInput, label: "system audio")
            }

            let rebasedPts = CMTimeSubtract(pts, sessionAnchor)
            if rebasedPts > lastAudioTime {
                lastAudioTime = rebasedPts
            }

            append(sampleBuffer, rebasedInto: audioInput, label: "audio")
        }
    }

    /// Appends a microphone audio sample buffer
    func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard let assetWriter,
                assetWriter.status == .writing,
                let microphoneInput,
                microphoneInput.isReadyForMoreMediaData
            else {
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startSessionIfNeeded(at: pts)

            if !hasPaddedMicrophone {
                hasPaddedMicrophone = true
                padWithSilence(sampleBuffer, into: microphoneInput, label: "microphone")
            }

            let rebasedPts = CMTimeSubtract(pts, sessionAnchor)
            if rebasedPts > lastAudioTime {
                lastAudioTime = rebasedPts
            }

            append(sampleBuffer, rebasedInto: microphoneInput, label: "microphone")
        }
    }

    // MARK: - Timing

    /// Opens the writing session on the first sample from any track.
    ///
    /// The anchor is shared by video and both audio tracks so they all resolve to a
    /// common origin of zero.
    private func startSessionIfNeeded(at presentationTime: CMTime) {
        guard !hasStartedSession, let assetWriter else { return }

        sessionAnchor = presentationTime
        hasStartedSession = true
        assetWriter.startSession(atSourceTime: .zero)
        logger.info("Session anchored at capture time: \(presentationTime.seconds)")
    }

    /// Writes silence covering the gap between the session anchor and this track's
    /// first sample, so the track begins at time zero.
    private func padWithSilence(
        _ sampleBuffer: CMSampleBuffer, into input: AVAssetWriterInput, label: String
    ) {
        let offset = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - sessionAnchor
        guard offset.isNumeric, offset > .zero,
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let silence = SilentAudioBuffer.make(
                matching: formatDescription, duration: offset, at: .zero)
        else {
            return
        }

        if input.append(silence) {
            logger.info("Padded \(label) with \(offset.seconds * 1000, format: .fixed(precision: 1))ms of silence")
        } else {
            logger.error("Failed to pad \(label) with silence")
        }
    }

    /// Rebases a sample buffer against the session anchor and appends it.
    private func append(
        _ sampleBuffer: CMSampleBuffer, rebasedInto input: AVAssetWriterInput, label: String
    ) {
        guard let rebased = rebase(sampleBuffer) else {
            logger.error("Failed to rebase \(label) sample buffer")
            return
        }

        if !input.append(rebased) {
            logger.error("Failed to append \(label) sample buffer")
        }
    }

    /// Returns a copy of `sampleBuffer` with its timestamps shifted so the session
    /// anchor maps to zero.
    private func rebase(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard var timings = try? sampleBuffer.sampleTimingInfos() else { return nil }

        for index in timings.indices {
            let rebasedPTS = CMTimeSubtract(
                timings[index].presentationTimeStamp, sessionAnchor)
            timings[index].presentationTimeStamp = max(rebasedPTS, .zero)
            if timings[index].decodeTimeStamp.isNumeric {
                let rebasedDTS = CMTimeSubtract(
                    timings[index].decodeTimeStamp, sessionAnchor)
                timings[index].decodeTimeStamp = max(rebasedDTS, .zero)
            }
        }

        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: CMItemCount(timings.count),
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        )

        guard status == noErr else { return nil }
        return copy
    }

    /// Clears all per-recording timing state.
    private func resetTimingState() {
        hasStartedSession = false
        sessionAnchor = .invalid
        lastVideoTime = .invalid
        lastAudioTime = .invalid
        hasLoggedFirstFrame = false
        hasPaddedAudio = false
        hasPaddedMicrophone = false
    }

    // MARK: - Finalization

    /// Finishes writing and finalizes the output file
    /// - Returns: The output URL and the number of video frames written. A count of zero
    ///            means the file holds audio only, which happens when the capture source
    ///            stopped producing frames while audio kept flowing.
    func finishWriting() async throws -> (url: URL, videoFrameCount: Int) {
        let (writerToFinish, url): (AVAssetWriter, URL)

        do {
            (writerToFinish, url) = try lock.withLockUnchecked {
                guard let assetWriter, isWriting else {
                    throw AssetWriterError.writerNotReady
                }

                guard let url = outputURL else {
                    throw AssetWriterError.noOutputURL
                }

                logger.info(
                    "Finishing writing - status: \(assetWriter.status.rawValue), session started: \(self.hasStartedSession), frames written: \(self.frameCount)"
                )

                guard hasStartedSession else {
                    logger.error("No frames were written - session was never started")
                    throw AssetWriterError.noFramesWritten
                }

                return (assetWriter, url)
            }
        } catch AssetWriterError.noFramesWritten {
            cancel()
            throw AssetWriterError.noFramesWritten
        }

        lock.withLockUnchecked {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            microphoneInput?.markAsFinished()
        }

        // Finalize writing to disk
        await writerToFinish.finishWriting()

        return try lock.withLockUnchecked {
            guard let assetWriter else {
                throw AssetWriterError.writerNotReady
            }

            if assetWriter.status == .failed {
                let error = assetWriter.error
                logger.error(
                    "AssetWriter failed: \(error?.localizedDescription ?? "unknown error")")
                throw AssetWriterError.writingFailed(error)
            }

            isWriting = false
            resetTimingState()

            logger.info(
                "AssetWriter finished writing \(self.frameCount) frames to: \(url.lastPathComponent)"
            )
            let videoFrameCount = frameCount
            frameCount = 0

            self.assetWriter = nil
            self.videoInput = nil
            self.pixelBufferAdaptor = nil
            self.audioInput = nil
            self.microphoneInput = nil
            self.outputURL = nil

            return (url, videoFrameCount)
        }
    }

    /// Cancels the current writing session
    func cancel() {
        lock.withLockUnchecked {
            assetWriter?.cancelWriting()
            isWriting = false
            resetTimingState()
            frameCount = 0

            // Clean up temp file if it exists
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }

            assetWriter = nil
            videoInput = nil
            pixelBufferAdaptor = nil
            audioInput = nil
            microphoneInput = nil
            outputURL = nil

            logger.info("AssetWriter cancelled")
        }
    }
}

// MARK: - CaptureEngineSampleBufferDelegate

extension AssetWriter {

    func captureEngine(
        _ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendVideoSample(sampleBuffer)
    }

    func captureEngine(
        _ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendAudioSample(sampleBuffer)
    }

    func captureEngine(
        _ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendMicrophoneSample(sampleBuffer)
    }
}
