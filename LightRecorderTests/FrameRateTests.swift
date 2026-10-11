//
//  FrameRateTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import XCTest
@testable import LightRecorder

final class FrameRateTests: XCTestCase {

    // MARK: - displayName

    func testDisplayNameNative() {
        XCTAssertEqual(FrameRate.native.displayName, "Native")
    }

    func testDisplayNameExplicitRates() {
        XCTAssertEqual(FrameRate.fps24.displayName, "24 fps")
        XCTAssertEqual(FrameRate.fps30.displayName, "30 fps")
        XCTAssertEqual(FrameRate.fps60.displayName, "60 fps")
    }

    // MARK: - effectiveFrameRate

    func testEffectiveFrameRateNativeIs60() {
        XCTAssertEqual(FrameRate.native.effectiveFrameRate, 60.0)
    }

    func testEffectiveFrameRateExplicitRates() {
        XCTAssertEqual(FrameRate.fps24.effectiveFrameRate, 24.0)
        XCTAssertEqual(FrameRate.fps30.effectiveFrameRate, 30.0)
        XCTAssertEqual(FrameRate.fps60.effectiveFrameRate, 60.0)
    }

    // MARK: - Identifiable & RawValue

    func testRawValues() {
        XCTAssertEqual(FrameRate.native.rawValue, 0)
        XCTAssertEqual(FrameRate.fps24.rawValue, 24)
        XCTAssertEqual(FrameRate.fps30.rawValue, 30)
        XCTAssertEqual(FrameRate.fps60.rawValue, 60)
    }

    func testIdentifiable() {
        for rate in FrameRate.allCases {
            XCTAssertEqual(rate.id, rate.rawValue)
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(FrameRate.allCases.count, 4)
    }
}
