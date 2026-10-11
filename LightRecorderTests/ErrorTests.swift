//
//  ErrorTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import XCTest
import Foundation
@testable import LightRecorder

/// Tests that all error types provide meaningful user-facing descriptions.
final class ErrorTests: XCTestCase {

    // MARK: - AssetWriterError

    func testAssetWriterErrorDescriptions() {
        let cases: [AssetWriterError] = [
            .failedToCreateWriter,
            .writerNotReady,
            .failedToStartWriting(nil),
            .writingFailed(nil),
            .noOutputURL,
            .noFramesWritten
        ]

        for error in cases {
            let description = error.errorDescription
            XCTAssertNotNil(description)
            XCTAssertFalse(description?.isEmpty ?? true)
        }
    }

    func testAssetWriterErrorWithUnderlyingError() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "test error"])
        let error1 = AssetWriterError.failedToStartWriting(underlying)
        let error2 = AssetWriterError.writingFailed(underlying)

        XCTAssertTrue(error1.errorDescription?.contains("test error") == true)
        XCTAssertTrue(error2.errorDescription?.contains("test error") == true)
    }

    // MARK: - CaptureError

    func testCaptureErrorDescriptions() {
        let cases: [CaptureError] = [
            .noContentFilterSelected,
            .failedToCreateStream,
            .captureAlreadyRunning,
            .screenRecordingPermissionDenied,
            .microphonePermissionDenied,
            .selectedDisplayDisconnected
        ]

        for error in cases {
            let description = error.errorDescription
            XCTAssertNotNil(description)
            XCTAssertFalse(description?.isEmpty ?? true)
        }
    }

    func testCaptureErrorScreenRecordingMentionsPermission() {
        let error = CaptureError.screenRecordingPermissionDenied
        XCTAssertTrue(error.errorDescription?.localizedStandardContains("permission") == true)
    }

    func testCaptureErrorMicrophoneMentionsPermission() {
        let error = CaptureError.microphonePermissionDenied
        XCTAssertTrue(error.errorDescription?.localizedStandardContains("permission") == true)
    }
}
