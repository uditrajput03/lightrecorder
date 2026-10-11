//
//  VideoQualityTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import AVFoundation
import XCTest
@testable import LightRecorder

final class VideoQualityTests: XCTestCase {

    // MARK: - h264BitsPerPixel

    func testH264BitsPerPixel() {
        XCTAssertEqual(VideoQuality.low.h264BitsPerPixel, 0.04)
        XCTAssertEqual(VideoQuality.medium.h264BitsPerPixel, 0.2)
        XCTAssertEqual(VideoQuality.high.h264BitsPerPixel, 0.6)
    }

    // MARK: - hevcBitsPerPixel

    func testHevcBitsPerPixel() {
        XCTAssertEqual(VideoQuality.low.hevcBitsPerPixel, 0.02)
        XCTAssertEqual(VideoQuality.medium.hevcBitsPerPixel, 0.15)
        XCTAssertEqual(VideoQuality.high.hevcBitsPerPixel, 0.4)
    }

    // MARK: - bitsPerPixel(for:)

    func testBitsPerPixelForH264() {
        XCTAssertEqual(VideoQuality.low.bitsPerPixel(for: .h264), 0.04)
        XCTAssertEqual(VideoQuality.medium.bitsPerPixel(for: .h264), 0.2)
        XCTAssertEqual(VideoQuality.high.bitsPerPixel(for: .h264), 0.6)
    }

    func testBitsPerPixelForHEVC() {
        XCTAssertEqual(VideoQuality.low.bitsPerPixel(for: .hevc), 0.02)
        XCTAssertEqual(VideoQuality.medium.bitsPerPixel(for: .hevc), 0.15)
        XCTAssertEqual(VideoQuality.high.bitsPerPixel(for: .hevc), 0.4)
    }

    // MARK: - HEVC is more efficient than H.264

    func testHevcMoreEfficientThanH264() {
        for quality in VideoQuality.allCases {
            XCTAssertTrue(quality.hevcBitsPerPixel < quality.h264BitsPerPixel)
        }
    }

    // MARK: - Identifiable & RawValue

    func testRawValues() {
        XCTAssertEqual(VideoQuality.low.rawValue, "Low")
        XCTAssertEqual(VideoQuality.medium.rawValue, "Medium")
        XCTAssertEqual(VideoQuality.high.rawValue, "High")
    }

    func testIdentifiable() {
        for quality in VideoQuality.allCases {
            XCTAssertEqual(quality.id, quality.rawValue)
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(VideoQuality.allCases.count, 3)
    }

    // MARK: - Bitrate Bounds

    @MainActor
    func testBitrateIsClampedForExtremeDimensions() {
        let store = SettingsStore()
        store.videoQuality = .high
        store.videoCodec = .h264
        store.frameRate = .fps60

        // 8K resolution: 7680 x 4320
        let largeSettings = AssetWriterSettings.video(from: store, size: CGSize(width: 7680, height: 4320))
        let compressionProps = largeSettings[AVVideoCompressionPropertiesKey] as? [String: Any]
        let largeBitrate = compressionProps?[AVVideoAverageBitRateKey] as? Int
        XCTAssertEqual(largeBitrate, 200_000_000)

        // Tiny size: 10 x 10
        let smallSettings = AssetWriterSettings.video(from: store, size: CGSize(width: 10, height: 10))
        let smallProps = smallSettings[AVVideoCompressionPropertiesKey] as? [String: Any]
        let smallBitrate = smallProps?[AVVideoAverageBitRateKey] as? Int
        XCTAssertEqual(smallBitrate, 1_000_000)
    }
}
