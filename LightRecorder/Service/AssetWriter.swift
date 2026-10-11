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
/// - Actively detects and fills audio discontinuities and startup latency with silence,
///   preventing audio drift over long recordings and system sleep/wake/device switch events.
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

    /// Timestamp when the last written system audio buffer ends, relative to `sessionAnchor`.
    private var lastSystemAudioEndTime: CMTime = .invalid

    /// Timestamp when the last written microphone buffer ends, relative to `sessionAnchor`.
    private var lastMicrophoneEndTime: CMTime = .invalid

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
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
            let attachments = attachmentsArray.first,
            let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue),
            status == .complete
        else {
            return
        }

        lock.withLockUnchecked {
            guard isWriting,
                  let assetWriter, assetWriter.status == .writing,
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
            guard isWriting,
                let assetWriter,
                assetWriter.status == .writing,
                let audioInput
            else {
                return
            }

            processAndAppendAudio(
                sampleBuffer,
                into: audioInput,
                label: "system audio",
                hasPadded: &hasPaddedAudio,
                lastEndTime: &lastSystemAudioEndTime
            )
        }
    }

    /// Appends a microphone audio sample buffer
    func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard isWriting,
                let assetWriter,
                assetWriter.status == .writing,
                let microphoneInput
            else {
                return
            }

            processAndAppendAudio(
                sampleBuffer,
                into: microphoneInput,
                label: "microphone",
                hasPadded: &hasPaddedMicrophone,
                lastEndTime: &lastMicrophoneEndTime
            )
        }
    }

    // MARK: - Audio Processing & Drift Prevention

    /// Handles timestamps, padding, silence gap filling, rebasing, and writing of audio sample buffers.
    private func processAndAppendAudio(
        _ sampleBuffer: CMSampleBuffer,
        into input: AVAssetWriterInput,
        label: String,
        hasPadded: inout Bool,
        lastEndTime: inout CMTime
    ) {
        guard input.isReadyForMoreMediaData else {
            logger.warning("\(label) input not ready for more media data; buffer dropped")
            return
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = rawPTS.isNumeric ? rawPTS : CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }
        let duration = sampleBufferDuration(sampleBuffer)

        startSessionIfNeeded(at: pts)

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            logger.error("No format description in \(label) sample buffer")
            return
        }

        if !hasPadded {
            let offset = CMTimeSubtract(pts, sessionAnchor)
            if offset < .zero {
                let bufferEnd = CMTimeAdd(pts, duration)
                if CMTimeSubtract(bufferEnd, sessionAnchor) <= .zero {
                    // Entire buffer ended before session started; drop it
                    return
                }
                // Buffer started before session anchor; skip it so subsequent buffer starts at/after anchor
                return
            }

            hasPadded = true
            if offset > CMTime(value: 1, timescale: 48000) {
                let padded = padSilence(
                    matching: formatDescription,
                    duration: offset,
                    at: .zero,
                    into: input,
                    label: label
                )
                lastEndTime = padded
            } else {
                lastEndTime = .zero
            }
        }

        let rebasedPTS = CMTimeSubtract(pts, sessionAnchor)

        // Mid-stream gap detection: if an audio gap exceeds 10ms (due to dropped buffers,
        // device disconnect, or audio stream pause), fill with silence to keep audio in sync.
        if lastEndTime.isNumeric && rebasedPTS > lastEndTime {
            let gap = CMTimeSubtract(rebasedPTS, lastEndTime)
            if gap > CMTime(value: 10, timescale: 1000) {
                let padded = padSilence(
                    matching: formatDescription,
                    duration: gap,
                    at: lastEndTime,
                    into: input,
                    label: label
                )
                lastEndTime = CMTimeAdd(lastEndTime, padded)
            }
        }

        // Ensure non-decreasing timestamps to prevent AVAssetWriter crashes on slight jitter
        let targetPTS = lastEndTime.isNumeric ? max(rebasedPTS, lastEndTime) : max(rebasedPTS, .zero)
        guard let rebased = rebase(sampleBuffer, to: targetPTS) else {
            logger.error("Failed to rebase \(label) sample buffer")
            return
        }

        if input.append(rebased) {
            lastEndTime = CMTimeAdd(targetPTS, duration)
        } else {
            logger.error("Failed to append \(label) sample buffer: \(self.assetWriter?.error?.localizedDescription ?? "unknown error")")
        }
    }

    /// Writes silence covering gaps or startup deltas in chunks of up to 5 seconds to bound memory usage.
    @discardableResult
    private func padSilence(
        matching formatDescription: CMFormatDescription,
        duration: CMTime,
        at startTime: CMTime,
        into input: AVAssetWriterInput,
        label: String
    ) -> CMTime {
        guard duration.isNumeric, duration > .zero else { return .zero }
        let maxChunkSeconds = 5.0
        var remaining = duration
        var currentPTS = startTime
        var totalPadded = CMTime.zero

        while remaining.seconds > 0.0001 {
            let chunkSec = min(remaining.seconds, maxChunkSeconds)
            let chunkDuration = CMTime(seconds: chunkSec, preferredTimescale: 48000)
            guard let silence = SilentAudioBuffer.make(
                matching: formatDescription,
                duration: chunkDuration,
                at: currentPTS
            ) else {
                break
            }

            let actualDuration = sampleBufferDuration(silence)
            let durationToAdvance = actualDuration > .zero ? actualDuration : chunkDuration

            if input.append(silence) {
                totalPadded = CMTimeAdd(totalPadded, durationToAdvance)
                currentPTS = CMTimeAdd(currentPTS, durationToAdvance)
                remaining = CMTimeSubtract(remaining, durationToAdvance)
            } else {
                logger.error("Failed to append silence chunk to \(label)")
                break
            }
        }

        if totalPadded > .zero {
            logger.info("Padded \(label) with \(totalPadded.seconds * 1000, format: .fixed(precision: 1))ms of silence")
        }
        return totalPadded
    }

    /// Computes the exact duration of an audio sample buffer.
    private func sampleBufferDuration(_ sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isNumeric && duration > .zero {
            return duration
        }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)
            if format.sampleRate > 0 {
                return CMTime(value: CMTimeValue(numSamples), timescale: CMTimeScale(format.sampleRate))
            }
        }
        return .zero
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

    /// Returns a copy of `sampleBuffer` with its timestamps shifted to `targetPTS`.
    private func rebase(_ sampleBuffer: CMSampleBuffer, to targetPTS: CMTime) -> CMSampleBuffer? {
        guard var timings = try? sampleBuffer.sampleTimingInfos() else { return nil }

        let rawOriginalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let originalPTS = rawOriginalPTS.isNumeric ? rawOriginalPTS : CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        if timings.isEmpty {
            let duration = sampleBufferDuration(sampleBuffer)
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            let sampleDuration = frameCount > 0 && duration.isNumeric
                ? CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / Double(frameCount))
                : .invalid
            timings = [CMSampleTimingInfo(
                duration: sampleDuration,
                presentationTimeStamp: targetPTS,
                decodeTimeStamp: .invalid
            )]
        } else {
            for index in timings.indices {
                let delta = originalPTS.isNumeric
                    ? CMTimeSubtract(timings[index].presentationTimeStamp, originalPTS)
                    : .zero
                timings[index].presentationTimeStamp = max(CMTimeAdd(targetPTS, delta), .zero)
                if timings[index].decodeTimeStamp.isNumeric {
                    let dtsDelta = originalPTS.isNumeric
                        ? CMTimeSubtract(timings[index].decodeTimeStamp, originalPTS)
                        : .zero
                    timings[index].decodeTimeStamp = max(CMTimeAdd(targetPTS, dtsDelta), .zero)
                }
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
        lastSystemAudioEndTime = .invalid
        lastMicrophoneEndTime = .invalid
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
            isWriting = false
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
