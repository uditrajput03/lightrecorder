//
//  PermissionService.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 07.02.26.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

import Combine

/// Service responsible for checking and requesting system permissions.
///
/// Designed to be lightweight like the default Windows Screen Recorder:
/// only requests Screen Recording and Microphone permissions, avoiding camera overhead.
@MainActor
final class PermissionService: ObservableObject {

    // MARK: - Permission States

    enum PermissionState {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var screenRecordingState: PermissionState = .unknown
    @Published private(set) var microphoneState: PermissionState = .unknown

    var allPermissionsGranted: Bool {
        screenRecordingState == .granted && microphoneState == .granted
    }

    var hasAnyPermissionDenied: Bool {
        screenRecordingState == .denied || microphoneState == .denied
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder",
        category: "PermissionService"
    )

    // MARK: - Initialization

    init() {
        updatePermissionStates()
    }

    // MARK: - Permission Checking

    /// Updates all permission states
    func updatePermissionStates() {
        screenRecordingState = checkScreenRecordingPermission()
        microphoneState = checkMicrophonePermission()

        let screen = String(describing: screenRecordingState)
        let microphone = String(describing: microphoneState)
        logger.info("Permission states - Screen: \(screen), Microphone: \(microphone)")
    }

    private func checkScreenRecordingPermission() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private func checkMicrophonePermission() -> PermissionState {
        state(for: .audio)
    }

    private func state(for mediaType: AVMediaType) -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .unknown
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .unknown
        }
    }

    // MARK: - Permission Requests

    /// Requests required permissions on app launch
    /// - Parameter includeMicrophone: Whether to also request microphone permission
    func requestPermissions(includeMicrophone: Bool) async {
        logger.info("Requesting permissions (includeMicrophone: \(includeMicrophone))...")

        // Request screen recording permission first (synchronous)
        requestScreenRecordingPermission()

        // Request microphone permission only if needed (asynchronous)
        if includeMicrophone {
            await requestMicrophonePermission()
        }

        // Update states after requests
        updatePermissionStates()
    }

    /// Requests screen recording permission
    /// - Note: This will open System Settings if permission was previously denied
    func requestScreenRecordingPermission() {
        let wasGranted = CGRequestScreenCaptureAccess()
        screenRecordingState = wasGranted ? .granted : .denied
        logger.info("Screen recording permission request result: \(wasGranted)")
    }

    /// Requests microphone permission
    func requestMicrophonePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            microphoneState = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneState = granted ? .granted : .denied
            logger.info("Microphone permission request result: \(granted)")
        case .denied, .restricted:
            microphoneState = .denied
        @unknown default:
            microphoneState = .unknown
        }
    }

    /// Opens System Settings to the Screen Recording preferences pane
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings to the Microphone preferences pane
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
