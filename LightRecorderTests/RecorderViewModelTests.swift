//
//  RecorderViewModelTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import XCTest
@testable import LightRecorder

/// Tests for RecorderViewModel's pure derived state and formatting.
///
/// These test the computed properties and initial state without
/// triggering any ScreenCaptureKit or system interactions.
@MainActor
final class RecorderViewModelTests: XCTestCase {

    // MARK: - formattedDuration

    func testFormattedDurationAtZero() {
        let viewModel = RecorderViewModel()
        XCTAssertEqual(viewModel.formattedDuration, "00:00")
    }

    // MARK: - Initial State

    func testInitialStateIsIdle() {
        let viewModel = RecorderViewModel()
        XCTAssertFalse(viewModel.isRecording)
        XCTAssertFalse(viewModel.isCountingDown)
    }

    func testCannotStartRecordingWithoutContentFilter() {
        let saved = UserDefaults.standard.string(forKey: ContentSelectionMode.storageKey)
        defer {
            UserDefaults.standard.set(saved, forKey: ContentSelectionMode.storageKey)
        }
        UserDefaults.standard.set(ContentSelectionMode.selectArea.rawValue, forKey: ContentSelectionMode.storageKey)

        let viewModel = RecorderViewModel()
        XCTAssertFalse(viewModel.canStartRecording)
    }

    func testCanStartRecordingWhenFullScreenMode() {
        let saved = UserDefaults.standard.string(forKey: ContentSelectionMode.storageKey)
        defer {
            UserDefaults.standard.set(saved, forKey: ContentSelectionMode.storageKey)
        }
        UserDefaults.standard.set(ContentSelectionMode.fullScreen.rawValue, forKey: ContentSelectionMode.storageKey)

        let viewModel = RecorderViewModel()
        XCTAssertTrue(viewModel.canStartRecording)
    }

    func testHasNoContentSelectedByDefault() {
        let viewModel = RecorderViewModel()
        XCTAssertFalse(viewModel.hasContentSelected)
    }

    func testIsNotAreaSelectionByDefault() {
        let viewModel = RecorderViewModel()
        XCTAssertFalse(viewModel.isAreaSelection)
    }

    func testLastErrorIsNilByDefault() {
        let viewModel = RecorderViewModel()
        XCTAssertNil(viewModel.lastError)
    }

    func testRecordingDurationIsZeroByDefault() {
        let viewModel = RecorderViewModel()
        XCTAssertEqual(viewModel.recordingDuration, 0)
    }

    func testCancelCountdownWhenNotCountingDownIsSafe() {
        let viewModel = RecorderViewModel()
        viewModel.cancelCountdown()
        XCTAssertFalse(viewModel.isCountingDown)
        XCTAssertFalse(viewModel.isRecording)
    }

    func testCaptureFilterStyleEquatable() {
        XCTAssertEqual(CaptureFilterStyle.display, CaptureFilterStyle.display)
        XCTAssertEqual(CaptureFilterStyle.application, CaptureFilterStyle.application)
        XCTAssertEqual(CaptureFilterStyle.window, CaptureFilterStyle.window)
        XCTAssertEqual(CaptureFilterStyle.unknown, CaptureFilterStyle.unknown)
        XCTAssertNotEqual(CaptureFilterStyle.display, CaptureFilterStyle.application)
        XCTAssertNotEqual(CaptureFilterStyle.window, CaptureFilterStyle.display)
    }

    func testAudioDeviceServiceLoadsDevicesWithoutCrashing() {
        let service = AudioDeviceService()
        XCTAssertNotNil(service.availableDevices)
        service.refreshDevices()
        XCTAssertNotNil(service.availableDevices)
    }
}
