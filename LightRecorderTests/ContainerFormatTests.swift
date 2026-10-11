//
//  ContainerFormatTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import XCTest
@testable import LightRecorder

final class ContainerFormatTests: XCTestCase {

    // MARK: - supportedVideoCodecs

    func testMovSupportsAllCodecs() {
        let codecs = ContainerFormat.mov.supportedVideoCodecs
        XCTAssertEqual(codecs, VideoCodec.allCases)
    }

    func testMp4SupportsOnlyH264AndHEVC() {
        let codecs = ContainerFormat.mp4.supportedVideoCodecs
        XCTAssertEqual(codecs, [.h264, .hevc])
    }

    // MARK: - supportedAudioCodecs

    func testMovSupportsAllAudioCodecs() {
        let codecs = ContainerFormat.mov.supportedAudioCodecs
        XCTAssertEqual(codecs, AudioCodec.allCases)
    }

    func testMp4SupportsOnlyAAC() {
        let codecs = ContainerFormat.mp4.supportedAudioCodecs
        XCTAssertEqual(codecs, [.aac])
        XCTAssertFalse(codecs.contains(.pcm))
    }

    // MARK: - fileExtension

    func testFileExtension() {
        XCTAssertEqual(ContainerFormat.mov.fileExtension, "mov")
        XCTAssertEqual(ContainerFormat.mp4.fileExtension, "mp4")
    }

    // MARK: - Identifiable & RawValue

    func testRawValues() {
        XCTAssertEqual(ContainerFormat.mov.rawValue, "mov")
        XCTAssertEqual(ContainerFormat.mp4.rawValue, "mp4")
    }

    func testIdentifiable() {
        for format in ContainerFormat.allCases {
            XCTAssertEqual(format.id, format.rawValue)
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(ContainerFormat.allCases.count, 2)
    }
}
