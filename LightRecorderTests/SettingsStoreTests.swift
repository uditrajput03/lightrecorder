//
//  SettingsStoreTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import XCTest
import Foundation
@testable import LightRecorder

/// Tests for SettingsStore's codec/container/audio validation logic.
///
/// Each test uses an isolated UserDefaults suite to avoid cross-test pollution.
@MainActor
final class SettingsStoreTests: XCTestCase {

    /// Creates a SettingsStore backed by a fresh, empty UserDefaults suite.
    private func makeStore() -> SettingsStore {
        let suiteName = "com.lightrecorder.LightRecorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return SettingsStore(defaults: defaults)
    }

    // MARK: - Default Values

    func testDefaultVideoCodecIsHEVC() {
        let store = makeStore()
        XCTAssertEqual(store.videoCodec, .hevc)
    }

    func testDefaultContainerFormatIsMOV() {
        let store = makeStore()
        XCTAssertEqual(store.containerFormat, .mov)
    }

    func testDefaultFrameRateIs60() {
        let store = makeStore()
        XCTAssertEqual(store.frameRate, .fps60)
    }

    func testDefaultVideoQualityIsMedium() {
        let store = makeStore()
        XCTAssertEqual(store.videoQuality, .medium)
    }

    func testDefaultAudioCodecIsAAC() {
        let store = makeStore()
        XCTAssertEqual(store.audioCodec, .aac)
    }

    func testDefaultCaptureNativeResolutionIsTrue() {
        let store = makeStore()
        XCTAssertTrue(store.captureNativeResolution)
    }

    func testDefaultShowCursorIsTrue() {
        let store = makeStore()
        XCTAssertTrue(store.showCursor)
    }

    func testDefaultShowLightRecorderIsFalse() {
        let store = makeStore()
        XCTAssertFalse(store.showLightRecorder)
    }

    func testDefaultCaptureSystemAudioIsTrue() {
        let store = makeStore()
        XCTAssertTrue(store.captureSystemAudio)
    }

    func testDefaultCaptureMicrophoneIsFalse() {
        let store = makeStore()
        XCTAssertFalse(store.captureMicrophone)
    }

    // MARK: - Codec/Container Compatibility

    func testH264AndHEVCWorkWithBothContainers() {
        let store = makeStore()

        store.containerFormat = .mp4
        store.videoCodec = .h264
        XCTAssertEqual(store.videoCodec, .h264)
        XCTAssertEqual(store.containerFormat, .mp4)

        store.videoCodec = .hevc
        XCTAssertEqual(store.videoCodec, .hevc)
        XCTAssertEqual(store.containerFormat, .mp4)

        store.containerFormat = .mov
        store.videoCodec = .h264
        XCTAssertEqual(store.videoCodec, .h264)
        XCTAssertEqual(store.containerFormat, .mov)
    }

    // MARK: - Audio Codec Compatibility

    func testPcmAudioIncompatibleWithMP4SwitchesContainer() {
        let store = makeStore()
        store.containerFormat = .mp4
        store.audioCodec = .pcm
        // Setting PCM on MP4 should switch container to MOV
        XCTAssertEqual(store.containerFormat, .mov)
        XCTAssertEqual(store.audioCodec, .pcm)
    }

    func testSwitchingToMP4WithPCMSwitchesAudioToAAC() {
        let store = makeStore()
        store.audioCodec = .pcm
        store.containerFormat = .mp4
        XCTAssertEqual(store.audioCodec, .aac)
        XCTAssertEqual(store.containerFormat, .mp4)
    }

    func testAacWorksWithBothContainers() {
        let store = makeStore()

        store.containerFormat = .mov
        store.audioCodec = .aac
        XCTAssertEqual(store.audioCodec, .aac)

        store.containerFormat = .mp4
        XCTAssertEqual(store.audioCodec, .aac)
    }

    // MARK: - Filename Generation

    func testGenerateFilenameFormat() {
        let store = makeStore()
        let filename = store.generateFilename()

        XCTAssertTrue(filename.hasPrefix("LightRecorder_"))
        XCTAssertTrue(filename.hasSuffix(".\(store.containerFormat.fileExtension)"))
    }

    func testGenerateFilenameUsesContainerExtension() {
        let store = makeStore()

        store.containerFormat = .mov
        XCTAssertTrue(store.generateFilename().hasSuffix(".mov"))

        store.containerFormat = .mp4
        XCTAssertTrue(store.generateFilename().hasSuffix(".mp4"))
    }

    // MARK: - Output Directory

    func testDefaultOutputDirectoryIsMoviesLightRecorder() {
        let store = makeStore()
        let expected = URL.homeDirectory.appending(path: "Movies/LightRecorder")
        XCTAssertEqual(store.defaultOutputDirectory, expected)
    }

    func testHasNoCustomOutputDirectoryByDefault() {
        let store = makeStore()
        XCTAssertFalse(store.hasCustomOutputDirectory)
    }

    func testOutputDirectoryUsesDefaultWhenNoCustomSet() {
        let store = makeStore()
        XCTAssertEqual(store.outputDirectory, store.defaultOutputDirectory)
    }

    func testResetOutputDirectoryClearsCustom() {
        let store = makeStore()
        store.resetOutputDirectory()
        XCTAssertFalse(store.hasCustomOutputDirectory)
    }

    // MARK: - Setting Persistence

    func testFrameRatePersists() {
        let store = makeStore()
        store.frameRate = .fps24
        XCTAssertEqual(store.frameRate, .fps24)
        store.frameRate = .native
        XCTAssertEqual(store.frameRate, .native)
    }

    func testVideoQualityPersists() {
        let store = makeStore()
        store.videoQuality = .high
        XCTAssertEqual(store.videoQuality, .high)
        store.videoQuality = .low
        XCTAssertEqual(store.videoQuality, .low)
    }

    func testVideoCodecPersists() {
        let store = makeStore()
        store.videoCodec = .h264
        XCTAssertEqual(store.videoCodec, .h264)
        store.videoCodec = .hevc
        XCTAssertEqual(store.videoCodec, .hevc)
    }

    func testLegacyH265DefaultsLoadsAsHEVC() {
        let suiteName = "com.lightrecorder.LightRecorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("H.265", forKey: "videoCodec")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.videoCodec, .hevc)
    }

    func testBooleanSettingsPersist() {
        let store = makeStore()

        store.captureMicrophone = true
        XCTAssertTrue(store.captureMicrophone)

        store.captureSystemAudio = true
        XCTAssertTrue(store.captureSystemAudio)

        store.showCursor = false
        XCTAssertFalse(store.showCursor)

        store.showWallpaper = false
        XCTAssertFalse(store.showWallpaper)

        store.showMenuBar = false
        XCTAssertFalse(store.showMenuBar)

        store.showDock = false
        XCTAssertFalse(store.showDock)

        store.showWindowShadows = false
        XCTAssertFalse(store.showWindowShadows)

        store.showLightRecorder = true
        XCTAssertTrue(store.showLightRecorder)

        store.captureNativeResolution = false
        XCTAssertFalse(store.captureNativeResolution)
    }

    // MARK: - Complex Cascade Scenarios

    func testSwitchingContainerToMP4CascadesAudioCodec() {
        let store = makeStore()
        // Start with a MOV-specific configuration (PCM audio)
        store.containerFormat = .mov
        store.videoCodec = .hevc
        store.audioCodec = .pcm
        XCTAssertEqual(store.audioCodec, .pcm)

        // Switch to MP4 — should cascade: audio -> AAC
        store.containerFormat = .mp4
        XCTAssertEqual(store.videoCodec, .hevc)
        XCTAssertEqual(store.audioCodec, .aac)
    }
}
