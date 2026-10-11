//
//  RecorderViewModel.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import Combine
import Foundation
import OSLog
import ScreenCaptureKit

/// The main view model managing recording state and coordination between services
@MainActor
final class RecorderViewModel: ObservableObject {

    // MARK: - Recording State

    enum RecordingState: Equatable {
        case idle
        case countdown
        case recording
        case stopping
    }

    // MARK: - Published Properties

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var lastError: Error?
    @Published private(set) var selectedContentFilter: SCContentFilter?

    /// The source rectangle for area selection (in display points, top-left origin)
    @Published private(set) var selectedSourceRect: CGRect?

    /// The selected area in screen coordinates (bottom-left origin), used for the border frame overlay
    private var selectedScreenRect: CGRect?

    /// The screen on which the area selection was made
    private var selectedScreen: NSScreen?

    /// Whether the current selection is an area selection (as opposed to a picker selection)
    var isAreaSelection: Bool {
        selectedSourceRect != nil
    }

    var isRecording: Bool {
        state == .recording
    }

    var isCountingDown: Bool {
        state == .countdown
    }

    var canStartRecording: Bool {
        state == .idle && (selectedContentFilter != nil || ContentSelectionMode.current == .fullScreen)
    }

    var hasContentSelected: Bool {
        selectedContentFilter != nil
    }

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    // MARK: - Dependencies

    let settings: SettingsStore
    let audioDeviceService: AudioDeviceService
    let notificationService: NotificationService
    let permissionService: PermissionService
    private let captureEngine: CaptureEngine
    private let assetWriter: AssetWriter

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder", category: "RecorderViewModel")

    // MARK: - Private Properties

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var videoSize: CGSize = .zero
    private let areaSelectionOverlay = AreaSelectionOverlay()
    private let selectionBorderFrame = SelectionBorderFrame()
    private let countdownOverlay = CountdownOverlay()

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.audioDeviceService = AudioDeviceService()
        self.notificationService = NotificationService(settings: settings)
        self.permissionService = PermissionService()
        self.captureEngine = CaptureEngine()
        self.assetWriter = AssetWriter()

        captureEngine.delegate = self
        captureEngine.sampleBufferDelegate = assetWriter
    }

    // MARK: - Permission Methods

    /// Requests required permissions on app launch
    /// Only requests microphone permission if microphone capture is enabled
    func requestPermissionsOnLaunch() async {
        await permissionService.requestPermissions(
            includeMicrophone: settings.captureMicrophone
        )
    }

    /// Refreshes the current permission states
    func refreshPermissions() {
        permissionService.updatePermissionStates()
    }

    // MARK: - Public Methods

    /// Toggles the recording state. If no content is selected, triggers the appropriate
    /// selection flow based on the user's content selection mode preference.
    func toggleRecording(copyToClipboard: Bool = false) async {
        if isRecording {
            await stopRecording(copyToClipboard: copyToClipboard)
        } else if isCountingDown {
            cancelCountdown()
        } else if hasContentSelected {
            await startRecording()
        } else {
            // No content selected — trigger selection based on the user's preferred mode
            switch ContentSelectionMode.current {
            case .fullScreen:
                await selectFullScreen()
                await startRecording()
            case .pickContent:
                presentPicker()
            case .selectArea:
                await presentAreaSelection()
            }
        }
    }

    /// Selects the entire display for capture
    func selectFullScreen(screen: NSScreen? = nil) async {
        do {
            let content = try await SCShareableContent.current
            let targetScreen = screen ?? NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }) ?? NSScreen.main ?? NSScreen.screens.first

            guard let targetScreen else {
                logger.error("No screen available for full screen capture")
                return
            }

            let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let targetDisplay = content.displays.first(where: { $0.displayID == screenNumber }) ?? content.displays.first else {
                logger.error("No SCDisplay found for screen")
                return
            }

            let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])

            captureEngine.clearSelection()
            captureEngine.deactivatePicker()

            selectedSourceRect = nil
            selectedScreenRect = nil
            selectedScreen = targetScreen
            selectedContentFilter = filter

            try await captureEngine.updateFilter(filter)
            selectionBorderFrame.dismiss()

            logger.info("Selected full screen on display \(targetDisplay.displayID)")
        } catch {
            logger.error("Failed to select full screen: \(error.localizedDescription)")
        }
    }

    /// Presents the system content sharing picker (or area selection on macOS 13)
    func presentPicker() {
        Task {
            await presentAreaSelection()
        }
    }

    /// Presents the area selection overlay on the display under the cursor
    func presentAreaSelection() async {
        // Dismiss any existing border frame so it doesn't overlap the selection overlay
        selectionBorderFrame.dismiss()

        guard let result = await areaSelectionOverlay.present() else {
            logger.info("Area selection cancelled")
            if isAreaSelection, let screenRect = selectedScreenRect {
                selectionBorderFrame.show(screenRect: screenRect)
            }
            return
        }

        // Show the border frame immediately so the user sees the selection outline
        selectionBorderFrame.show(screenRect: result.screenRect)

        // Find the corresponding SCDisplay for the selected screen
        do {
            let content = try await SCShareableContent.current
            let screenNumber = result.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

            guard let display = content.displays.first(where: { $0.displayID == screenNumber }) else {
                logger.error("Could not find SCDisplay for selected screen")
                return
            }

            // Create a content filter for the full display
            let filter = SCContentFilter(display: display, excludingWindows: [])

            // Convert screen rect (NSScreen coordinates, bottom-left origin) to
            // sourceRect (display coordinates, top-left origin)
            // NSScreen dimensions are in points, matching sourceRect coordinates.
            let displayHeight = result.screen.frame.height
            let screenOrigin = result.screen.frame.origin

            let localX = result.screenRect.origin.x - screenOrigin.x
            let localY = result.screenRect.origin.y - screenOrigin.y

            // Flip Y: NSScreen has origin at bottom-left, sourceRect uses top-left (both in points)
            let flippedY = displayHeight - localY - result.screenRect.height

            // Snap dimensions to even pixel counts for codec compatibility
            let scale = result.screen.backingScaleFactor
            let pixelWidth = result.screenRect.width * scale
            let pixelHeight = result.screenRect.height * scale
            let evenPixelWidth = ceil(pixelWidth / 2) * 2
            let evenPixelHeight = ceil(pixelHeight / 2) * 2

            let sourceRect = CGRect(
                x: localX,
                y: flippedY,
                width: evenPixelWidth / scale,
                height: evenPixelHeight / scale
            )

            // Clear any existing picker selection (mutually exclusive)
            captureEngine.clearSelection()
            captureEngine.deactivatePicker()

            // Store the area selection and set the filter on the capture engine
            selectedSourceRect = sourceRect
            selectedScreenRect = result.screenRect
            selectedScreen = result.screen
            selectedContentFilter = filter
            try await captureEngine.updateFilter(filter)

            logger.info("Area selected: sourceRect=\(sourceRect.debugDescription), display=\(display.displayID)")
        } catch {
            selectionBorderFrame.dismiss()
            logger.error("Failed to get shareable content for area selection: \(error.localizedDescription)")
        }
    }

    /// Cancels any active countdown before recording starts
    func cancelCountdown() {
        countdownOverlay.cancel()
        state = .idle
    }

    /// Starts a new recording session
    func startRecording() async {
        if selectedContentFilter == nil && ContentSelectionMode.current == .fullScreen {
            await selectFullScreen()
        }

        guard canStartRecording else {
            logger.warning("Cannot start recording: no content selected or already recording")
            return
        }

        // Dismiss menu bar extra window so it doesn't linger on screen
        dismissMenuBarWindow()

        // Countdown if enabled
        if settings.countdownDuration != .off {
            state = .countdown
            let screen = selectedScreen ?? NSScreen.main ?? NSScreen.screens.first
            let targetRect = selectedScreenRect ?? screen?.frame ?? .zero
            let targetScreen = screen ?? NSScreen.main

            if let targetScreen {
                let finished = await countdownOverlay.startCountdown(
                    seconds: settings.countdownDuration.rawValue,
                    in: targetRect,
                    on: targetScreen
                )

                guard finished, state == .countdown else {
                    logger.info("Recording countdown cancelled or interrupted")
                    state = .idle
                    return
                }
            }
        }

        do {
            lastError = nil

            logger.info("Starting recording sequence...")

            // Determine video size from filter
            if let filter = selectedContentFilter {
                videoSize = await getContentSize(from: filter)
            }
            logger.info("Video size: \(self.videoSize.width)x\(self.videoSize.height)")

            // Access security-scoped output directory before writing
            _ = settings.startAccessingOutputDirectory()

            // Setup asset writer
            let outputURL = settings.generateOutputURL()
            try assetWriter.setup(url: outputURL, settings: settings, videoSize: videoSize)
            try assetWriter.startWriting()
            logger.info("AssetWriter ready")

            // Start capture with the calculated video size
            logger.info("Starting capture engine...")
            try await captureEngine.startCapture(with: settings, videoSize: videoSize, sourceRect: selectedSourceRect)

            state = .recording

            // Re-show the area selection border now that capture has started
            if isAreaSelection, let screenRect = selectedScreenRect {
                selectionBorderFrame.show(screenRect: screenRect)
            }

            // Start timer
            startTimer()

            logger.info("Recording started")

        } catch {
            state = .idle
            lastError = error
            selectionBorderFrame.dismiss()

            // The writer may already be set up and holding an empty output file. Cancel it
            // before releasing the output directory, since that is where the file lives.
            assetWriter.cancel()
            settings.stopAccessingOutputDirectory()

            // lastError has no UI representation, so every start failure has to be surfaced
            // as a notification - otherwise the record button silently does nothing.
            notificationService.sendRecordingStartFailedNotification(error: error)

            // The selection points at a display that is gone, so drop it. The next recording
            // attempt then opens the picker instead of failing the same way again.
            if error as? CaptureError == .selectedDisplayDisconnected {
                await resetSelection()
            }

            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops the current recording session
    func stopRecording(copyToClipboard: Bool = false) async {
        if isCountingDown {
            cancelCountdown()
            return
        }

        guard isRecording else { return }

        state = .stopping
        stopTimer()
        selectionBorderFrame.dismiss()
        dismissMenuBarWindow()

        do {
            // Stop capture
            try await captureEngine.stopCapture()

            // Finalize file
            let (outputURL, videoFrameCount) = try await assetWriter.finishWriting()

            state = .idle
            recordingDuration = 0

            logger.info("Recording stopped and saved to: \(outputURL.lastPathComponent)")

            // Send notification. The file is kept either way - an audio-only recording is
            // still worth more than a deleted one - but the user has to be told about it.
            if videoFrameCount == 0 {
                logger.error("Recording contains no video frames: \(outputURL.lastPathComponent)")
                notificationService.sendRecordingMissingVideoNotification(fileURL: outputURL)
            } else {
                notificationService.sendRecordingSavedNotification(fileURL: outputURL)
            }

            if copyToClipboard {
                copyFileToClipboard(outputURL)
            }

            settings.stopAccessingOutputDirectory()

        } catch {
            state = .idle
            lastError = error
            assetWriter.cancel()
            settings.stopAccessingOutputDirectory()
            notificationService.sendRecordingFailedNotification(error: error)
            logger.error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    /// Dismisses any open menu bar extra window if present
    private func dismissMenuBarWindow() {
        for window in NSApp.windows where window.className.contains("MenuBarExtraWindow") {
            window.orderOut(nil)
        }
    }

    /// Resets the capture selection, removing the border frame and clearing state
    ///
    /// Covers both area and picker selections, so the capture engine's filter is cleared
    /// alongside the view model's - otherwise the engine keeps a filter the UI no longer shows.
    func resetSelection() async {
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectedScreen = nil
        selectedContentFilter = nil
        captureEngine.clearSelection()
        captureEngine.deactivatePicker()
        selectionBorderFrame.dismiss()
    }

    // MARK: - Timer Management

    private func startTimer() {
        recordingStartTime = Date()
        recordingDuration = 0

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Helper Methods

    private func copyFileToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func getContentSize(from filter: SCContentFilter) async -> CGSize {
        // Apply scale if Capture Native Resolution setting is enabled
        let applyScale: Bool = settings.captureNativeResolution

        // If area selection is active, use the source rect dimensions.
        // The sourceRect is already snapped to even pixel counts in presentAreaSelection().
        if let sourceRect = selectedSourceRect {
            let scale: CGFloat = selectedScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
            let size = CaptureSizeCalculator.videoSize(
                contentRect: sourceRect,
                scale: scale,
                useNativeResolution: applyScale
            )
            return CGSize(
                width: ceil(size.width / 2) * 2,
                height: ceil(size.height / 2) * 2
            )
        }

        // Fallback to screen size
        if let screen = selectedScreen ?? NSScreen.main {
            let rawWidth = applyScale ? screen.frame.width * screen.backingScaleFactor : screen.frame.width
            let rawHeight = applyScale ? screen.frame.height * screen.backingScaleFactor : screen.frame.height
            return CGSize(
                width: ceil(rawWidth / 2) * 2,
                height: ceil(rawHeight / 2) * 2
            )
        }

        return CGSize(width: 1920, height: 1080)
    }

    /// The point-to-pixel scale to size the capture with.
    private func pointPixelScale(for filter: SCContentFilter) -> CGFloat {
        selectedScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
    }

    /// The connected displays in the global CoreGraphics space that `SCWindow.frame` uses.
    private static func connectedDisplays() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return DisplayGeometry(frame: CGDisplayBounds(displayID), scaleFactor: screen.backingScaleFactor)
        }
    }
}

// MARK: - CaptureEngineDelegate

extension RecorderViewModel: CaptureEngineDelegate {

    func captureEngine(_ engine: CaptureEngine, didUpdateFilter filter: SCContentFilter) {
        // Clear any area selection (picker and area selections are mutually exclusive)
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectedScreen = nil
        selectionBorderFrame.dismiss()

        selectedContentFilter = filter
        logger.info("Content filter updated")
    }

    func captureEngine(_ engine: CaptureEngine, didStopWithError error: Error?) {
        // Check if user clicked "Stop Sharing" in the menu bar
        let isUserStopped = (error as? SCStreamError)?.code == .userStopped

        if let error, !isUserStopped {
            lastError = error
            logger.error("Capture stopped with error: \(error.localizedDescription)")
        }

        // Clean up if we were recording
        if isRecording {
            if isUserStopped {
                // User clicked "Stop Sharing" - gracefully save the recording
                logger.info("User stopped sharing via system UI, saving recording...")
                Task {
                    await stopRecording()
                }
            } else {
                // Stream error during recording - try to save what we have
                logger.warning("Stream stopped unexpectedly, attempting to save recording...")
                Task {
                    await stopRecording()
                }
            }
        }
    }

    func captureEngine(_ engine: CaptureEngine, systemAudioDidFailWith error: Error?) {
        // The video recording keeps running; only system audio is missing from the output
        logger.error("System audio capture failed: \(error?.localizedDescription ?? "unknown error")")
        notificationService.sendSystemAudioFailedNotification(error: error)
    }

    func captureEngineDidCancelPicker(_ engine: CaptureEngine) {
        logger.info("Picker was cancelled, clearing selection")
        selectedContentFilter = nil
    }
}
