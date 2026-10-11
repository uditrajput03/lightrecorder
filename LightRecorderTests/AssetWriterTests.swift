//
//  AssetWriterTests.swift
//  LightRecorderTests
//
//  Created by Krishna Ramaroson on 28.07.26.
//

import AVFoundation
import ScreenCaptureKit
import XCTest
@testable import LightRecorder

/// Tests for the video frame count AssetWriter reports when finishing a recording.
///
/// A capture source that stops delivering frames - a disconnected display, for example -
/// while audio keeps flowing produces a file with audio tracks and no video track. The
/// frame count is what lets the caller detect that case.
@MainActor
final class AssetWriterTests: XCTestCase {

    private let videoSize = CGSize(width: 640, height: 480)

    // MARK: - Tests

    func testAudioOnlyRecordingReportsZeroVideoFrames() async throws {
        let settings = makeStore()
        settings.captureSystemAudio = true

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        // Audio flows for the whole session, no video sample ever arrives
        for index in 0..<10 {
            let presentationTime = CMTime(value: CMTimeValue(index * 1024), timescale: 48000)
            assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: presentationTime))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 0)

        // The recording is kept - audio is still worth saving - and it holds no video track
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        let videoTracks = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)
        XCTAssertTrue(videoTracks.isEmpty)
    }

    func testRecordingWithVideoReportsFramesWritten() async throws {
        let settings = makeStore()

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        for index in 0..<5 {
            let presentationTime = CMTime(value: CMTimeValue(index), timescale: 60)
            assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: presentationTime))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 5)
    }

    func testCrashResilientRecordingWritesPlayableFile() async throws {
        let settings = makeStore()
        settings.crashResilientRecording = true
        settings.containerFormat = .mp4
        settings.videoCodec = .h264

        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        let assetWriter = AssetWriter()
        try assetWriter.setup(url: url, settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        for index in 0..<5 {
            let presentationTime = CMTime(value: CMTimeValue(index), timescale: 60)
            assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: presentationTime))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))

        let asset = AVURLAsset(url: result.url)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
    }

    func testCancelAfterFinishingDoesNotDeleteTheSavedRecording() async throws {
        let settings = makeStore()

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()
        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        // A failed setup for the next recording leaves the previous session's state in place,
        // and the recovery path cancels the writer. The saved file must survive that.
        assetWriter.cancel()

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testRecordingWithoutAnySampleThrows() async throws {
        let settings = makeStore()

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        do {
            _ = try await assetWriter.finishWriting()
            XCTFail("Expected AssetWriterError to be thrown")
        } catch is AssetWriterError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Direct VFR Encoding (Lightweight)

    /// In lightweight VFR encoding, jittered frames with strictly increasing timestamps
    /// are encoded directly without loss or forced grid quantization.
    func testJitteredArrivalsAreWrittenMonotonically() async throws {
        let settings = makeStore()
        settings.frameRate = .fps30

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        for milliseconds in [0, 30, 63, 98, 137, 165] {
            let time = CMTime(value: CMTimeValue(milliseconds), timescale: 1000)
            assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: time))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 6)
        let times = try await videoPresentationTimes(of: result.url)
        XCTAssertTrue(isStrictlyIncreasing(times))
    }

    /// During static screen content, ScreenCaptureKit stops delivering frames.
    /// Lightweight direct encoding leaves the encoder idle rather than generating synthetic
    /// duplicate frames, saving CPU, GPU, and battery.
    func testStalledCaptureDoesNotDuplicateFrames() async throws {
        let settings = makeStore()
        settings.frameRate = .fps30

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))
        // One second of static screen content
        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: CMTime(value: 1, timescale: 1)))

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        // Exactly 2 frames are written without synthetic duplicates filling the stall
        XCTAssertEqual(result.videoFrameCount, 2)
        let times = try await videoPresentationTimes(of: result.url)
        XCTAssertEqual(times.count, 2)
        XCTAssertTrue(isStrictlyIncreasing(times))
    }

    /// Duplicate timestamps on the same track would corrupt the container;
    /// they are dropped safely.
    func testDuplicateTimestampsAreDropped() async throws {
        let settings = makeStore()
        settings.frameRate = .fps30

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))
        // Frame with identical presentation time
        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 1)
    }

    /// Capture jitter or driver resets can emit non-monotonic timestamps.
    /// Non-monotonic frames are dropped cleanly without failing the writer.
    func testNonMonotonicTimestampsDoNotFailTheWriter() async throws {
        let settings = makeStore()
        settings.frameRate = .fps30

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        for milliseconds in [0, 33, 67, 20, 100] {
            let time = CMTime(value: CMTimeValue(milliseconds), timescale: 1000)
            assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: time))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        // The out-of-order frame is dropped, the rest are written in order
        XCTAssertEqual(result.videoFrameCount, 4)
        let times = try await videoPresentationTimes(of: result.url)
        XCTAssertTrue(isStrictlyIncreasing(times))
    }

    /// A microphone can take hundreds of milliseconds to start delivering samples. The
    /// head of the track is padded with silence so it still begins at zero, which is
    /// what keeps concatenated recordings in sync.
    func testLateMicrophoneIsPaddedWithSilence() async throws {
        let settings = makeStore()
        settings.captureSystemAudio = true
        settings.captureMicrophone = true
        settings.audioCodec = .pcm
        settings.frameRate = .fps30

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))
        assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: .zero))

        // Microphone spins up 324 ms late, as measured on a real recording
        let micStart = CMTime(value: 324, timescale: 1000)
        for index in 0..<10 {
            let offset = CMTime(value: CMTimeValue(index * 1024), timescale: 48000)
            assetWriter.appendMicrophoneSample(
                try makeSilentAudioSampleBuffer(at: micStart + offset))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        let asset = AVURLAsset(url: result.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 2)

        for track in audioTracks {
            let timeRange = try await track.load(.timeRange)
            XCTAssertEqual(timeRange.start, .zero)
        }
    }

    /// A mid-stream gap in audio (e.g. system sleep, audio device change, or dropped buffer)
    /// must be padded with silence so the audio track stays in sync with video.
    func testMidStreamAudioGapIsPaddedWithSilence() async throws {
        let settings = makeStore()
        settings.captureSystemAudio = true
        settings.audioCodec = .pcm
        settings.frameRate = .fps30

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        // Video runs from 0 to 800ms
        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))
        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: CMTime(value: 800, timescale: 1000)))

        // Initial 3 audio buffers (approx 64ms)
        for index in 0..<3 {
            let pts = CMTime(value: CMTimeValue(index * 1024), timescale: 48000)
            assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: pts))
        }

        // Gap of ~500ms before next audio sample
        let gapStart = CMTime(value: 564, timescale: 1000)
        for index in 0..<3 {
            let offset = CMTime(value: CMTimeValue(index * 1024), timescale: 48000)
            assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: gapStart + offset))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        let asset = AVURLAsset(url: result.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let timeRange = try await audioTrack.load(.timeRange)

        // Without gap padding, 6 buffers is only ~128ms. With gap padding, duration is >= 600ms.
        XCTAssertGreaterThan(timeRange.duration.seconds, 0.60)
    }

    /// Audio buffers captured before the video session anchor starts must not cause
    /// duplicate zeros, negative timestamps, or writer errors.
    func testAudioPriorToVideoAnchorIsDroppedSafely() async throws {
        let settings = makeStore()
        settings.captureSystemAudio = true

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        // Video establishes session anchor at 2.0s
        let anchorTime = CMTime(value: 2000, timescale: 1000)
        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: anchorTime))

        // Audio arriving with timestamp before anchor (e.g. 1.5s)
        let preAnchorTime = CMTime(value: 1500, timescale: 1000)
        assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: preAnchorTime))

        // Post-anchor audio
        let postAnchorTime = CMTime(value: 2050, timescale: 1000)
        assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: postAnchorTime))

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 1)
        let asset = AVURLAsset(url: result.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let timeRange = try await audioTrack.load(.timeRange)
        XCTAssertEqual(timeRange.start, .zero)
    }

    /// Audio packets with minor negative timestamp jitter from audio clocking are
    /// clamped forward monotonically without crashing or failing the writer.
    func testAudioJitterDoesNotFailWriter() async throws {
        let settings = makeStore()
        settings.captureSystemAudio = true

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))

        // Audio buffers arriving with minor backward jitter
        let timesInMilliseconds = [0, 21, 20, 42, 40, 64]
        for ms in timesInMilliseconds {
            let pts = CMTime(value: CMTimeValue(ms), timescale: 1000)
            assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: pts))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 1)
    }

    /// Audio buffers created without a pre-existing timing info array (common from audio units)
    /// must be safely rebased with synthesized timing rather than producing NaN PTS or failing.
    func testAudioWithEmptyTimingArrayIsRebasedAndAppended() async throws {
        let settings = makeStore()
        settings.captureSystemAudio = true

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))

        // Buffer without pre-populated timing array
        let buffer = try makeSilentAudioSampleBufferWithEmptyTiming(at: .zero)
        assetWriter.appendAudioSample(buffer)

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertEqual(result.videoFrameCount, 1)
        let asset = AVURLAsset(url: result.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }

    // MARK: - Helpers

    private func isStrictlyIncreasing(_ times: [CMTime]) -> Bool {
        zip(times, times.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// Reads back every video frame's presentation timestamp, in presentation order.
    ///
    /// Decoding rather than reading compressed samples keeps the output one buffer per
    /// frame in presentation order, free of the container's edit and marker buffers.
    private func videoPresentationTimes(of url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }

        return times
    }

    /// Creates a SettingsStore backed by a fresh, empty UserDefaults suite.
    private func makeStore() -> SettingsStore {
        let suiteName = "com.lightrecorder.LightRecorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return SettingsStore(defaults: defaults)
    }

    private func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
    }

    /// Creates a buffer of silent 48 kHz stereo audio.
    private func makeSilentAudioSampleBuffer(at presentationTime: CMTime) throws -> CMSampleBuffer {
        let frameCount: AVAudioFrameCount = 1024

        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)
        )
        let pcmBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        pcmBuffer.frameLength = frameCount

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(createStatus, noErr)

        let buffer = try XCTUnwrap(sampleBuffer)
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcmBuffer.mutableAudioBufferList
        )
        XCTAssertEqual(attachStatus, noErr)

        return buffer
    }

    /// Creates a buffer of silent audio without pre-populating sample timing infos.
    private func makeSilentAudioSampleBufferWithEmptyTiming(at presentationTime: CMTime) throws -> CMSampleBuffer {
        let frameCount: AVAudioFrameCount = 1024

        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)
        )
        let byteCount = Int(frameCount) * 4

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, noErr)
        let block = try XCTUnwrap(blockBuffer)

        let fillStatus = CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        XCTAssertEqual(fillStatus, noErr)

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(createStatus, noErr)

        let buffer = try XCTUnwrap(sampleBuffer)
        CMSampleBufferSetOutputPresentationTimeStamp(buffer, newValue: presentationTime)

        return buffer
    }

    /// Creates an empty BGRA video frame marked complete, as ScreenCaptureKit would deliver it.
    private func makeVideoSampleBuffer(at presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let pixelBufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(videoSize.width),
            Int(videoSize.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: NSDictionary()] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(pixelBufferStatus, kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(formatStatus, noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        let videoFormat = try XCTUnwrap(formatDescription)

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: videoFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(createStatus, noErr)
        let buffer = try XCTUnwrap(sampleBuffer)

        // appendVideoSample only accepts frames the capture engine marked complete
        let attachments = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [NSMutableDictionary]
        )
        let attachment = try XCTUnwrap(attachments.first)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue

        return buffer
    }
}
