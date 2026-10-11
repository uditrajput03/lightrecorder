//
//  SilentAudioBufferTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import AVFoundation
import XCTest
@testable import LightRecorder

/// Tests for the silence used to pad the head of audio tracks that start late.
final class SilentAudioBufferTests: XCTestCase {

    func testSilenceCoversTheRequestedDuration() throws {
        let format = try makeFormat()
        let duration = CMTime(value: 324, timescale: 1000)

        let buffer = try XCTUnwrap(
            SilentAudioBuffer.make(
                matching: format.formatDescription, duration: duration, at: .zero)
        )

        // 324 ms at 48 kHz
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 15552)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), .zero)
        XCTAssertTrue(abs(CMSampleBufferGetDuration(buffer).seconds - duration.seconds) < 0.001)
    }

    func testSilenceMatchesTheSourceFormat() throws {
        let format = try makeFormat()

        let buffer = try XCTUnwrap(
            SilentAudioBuffer.make(
                matching: format.formatDescription,
                duration: CMTime(value: 1, timescale: 10),
                at: .zero)
        )

        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer))
        let asbd = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)

        XCTAssertEqual(asbd.mSampleRate, 48000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    }

    func testSamplesAreSilent() throws {
        let format = try makeFormat()

        let buffer = try XCTUnwrap(
            SilentAudioBuffer.make(
                matching: format.formatDescription,
                duration: CMTime(value: 1, timescale: 100),
                at: .zero)
        )

        let blockBuffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
            dataPointerOut: &pointer)

        XCTAssertEqual(status, noErr)
        XCTAssertTrue(length > 0)

        let bytes = try XCTUnwrap(pointer)
        let nonZero = (0..<length).contains { bytes[$0] != 0 }
        XCTAssertFalse(nonZero)
    }

    func testHonoursThePresentationTime() throws {
        let format = try makeFormat()
        let presentationTime = CMTime(value: 5, timescale: 100)

        let buffer = try XCTUnwrap(
            SilentAudioBuffer.make(
                matching: format.formatDescription,
                duration: CMTime(value: 1, timescale: 100),
                at: presentationTime)
        )

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), presentationTime)
    }

    func testRejectsNonPositiveDurations() throws {
        let format = try makeFormat()
        let invalidDurations = [CMTime.zero, CMTime(value: -1, timescale: 10), CMTime.invalid]

        for duration in invalidDurations {
            XCTAssertNil(
                SilentAudioBuffer.make(
                    matching: format.formatDescription, duration: duration, at: .zero)
            )
        }
    }

    func testRejectsDurationsShorterThanOneFrame() throws {
        let format = try makeFormat()

        // Well under half a sample period at 48 kHz, so it rounds to zero frames
        XCTAssertNil(
            SilentAudioBuffer.make(
                matching: format.formatDescription,
                duration: CMTime(value: 1, timescale: 1_000_000),
                at: .zero)
        )
    }

    // MARK: - Helpers

    private func makeFormat() throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)
        )
    }
}
