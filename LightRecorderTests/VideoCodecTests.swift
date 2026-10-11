//
//  VideoCodecTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import XCTest
@testable import LightRecorder

final class VideoCodecTests: XCTestCase {

    // MARK: - supportsQualitySetting

    func testSupportsQualitySetting() {
        XCTAssertTrue(VideoCodec.h264.supportsQualitySetting)
        XCTAssertTrue(VideoCodec.hevc.supportsQualitySetting)
    }

    // MARK: - Identifiable & RawValue

    func testRawValues() {
        XCTAssertEqual(VideoCodec.h264.rawValue, "H.264")
        XCTAssertEqual(VideoCodec.hevc.rawValue, "H.265")
    }

    func testIdentifiable() {
        for codec in VideoCodec.allCases {
            XCTAssertEqual(codec.id, codec.rawValue)
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(VideoCodec.allCases.count, 2)
    }
}
