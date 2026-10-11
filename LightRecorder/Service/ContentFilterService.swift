//
//  ContentFilterService.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import OSLog
import CoreGraphics
import AVFoundation

/// Service responsible for applying content filter settings (wallpaper, dock, menu bar)
@MainActor
final class ContentFilterService {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder", category: "ContentFilterService")

    /// Checks if screen recording permission has been granted
    /// - Returns: true if permission is granted
    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests screen recording permission from the user
    /// - Returns: true if permission was granted (or was already granted)
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Checks if microphone permission has been granted
    /// - Returns: true if permission is granted
    func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Requests microphone permission from the user
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Checks whether the display targeted by a filter is still connected
    func isSelectedDisplayConnected(_ filter: SCContentFilter) async -> Bool {
        guard let content = try? await SCShareableContent.current else { return true }
        if let display = (filter as NSObject).value(forKey: "display") as? SCDisplay {
            return content.displays.contains(where: { $0.displayID == display.displayID })
        }
        return !content.displays.isEmpty
    }

    /// Applies user settings to a content filter
    func applySettings(to filter: SCContentFilter, settings: SettingsStore) async throws -> SCContentFilter {
        let visibility = ContentVisibility(settings: settings)
        guard ContentFilterRules.requiresRebuild(visibility: visibility) else {
            return filter
        }

        guard let content = try? await SCShareableContent.current else {
            return filter
        }

        let capturableWindows = content.windows.map(CapturableWindow.init)
        let excludedIDs = Set(ContentFilterRules.excludedWindowIDs(from: capturableWindows, visibility: visibility))
        let windowsToExclude = content.windows.filter { excludedIDs.contains($0.windowID) }

        // Retrieve display from filter or fallback to primary display
        let display = (filter as NSObject).value(forKey: "display") as? SCDisplay ?? content.displays.first

        guard let targetDisplay = display else {
            return filter
        }

        // Also merge any existing excluded windows
        let existingExcluded = (filter as NSObject).value(forKey: "excludedWindows") as? [SCWindow] ?? []
        var combinedExcluded = windowsToExclude
        for window in existingExcluded where !combinedExcluded.contains(where: { $0.windowID == window.windowID }) {
            combinedExcluded.append(window)
        }

        let filterSummary = "wallpaper: \(visibility.showWallpaper), dock: \(visibility.showDock), lightRecorder: \(visibility.showLightRecorder)"
        logger.info("Applying content filter: excluding \(combinedExcluded.count) window(s) (\(filterSummary))")

        return SCContentFilter(display: targetDisplay, excludingWindows: combinedExcluded)
    }
}

// MARK: - CapturableWindow Bridging

private extension CapturableWindow {

    /// Reduces a ScreenCaptureKit window to the properties the filter rules need
    init(_ window: SCWindow) {
        self.init(
            id: window.windowID,
            bundleID: window.owningApplication?.bundleIdentifier ?? "",
            title: window.title ?? ""
        )
    }
}
