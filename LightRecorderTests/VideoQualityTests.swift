//
//  VideoQualityTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

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
}
