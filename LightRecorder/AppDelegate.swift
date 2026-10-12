//
//  AppDelegate.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 30.08.26.
//

import AppKit
import KeyboardShortcuts
import OSLog

/// Owns the recorder, registers the global keyboard shortcuts, and handles
/// `lightrecorder://` URLs.
///
/// None of this can live on the `MenuBarExtra` scene. SwiftUI only routes external
/// events such as URLs to window-presenting scenes, and the menu bar content is not built
/// until the user first opens the popover, so neither `onOpenURL` nor a `.task` there ever
/// runs at launch. `NSApplicationDelegate` is active from launch onwards, which is why the
/// recorder is owned here: it has to be reachable without the popover ever being opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let viewModel = RecorderViewModel()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder", category: "AppDelegate")
    private var localEventMonitor: Any?
    private weak var statusBarButton: NSStatusBarButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerKeyboardShortcuts()
        setupStatusBarClickInterception()
        Task {
            await viewModel.requestPermissionsOnLaunch()
        }
    }

    deinit {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "lightrecorder" {
            handle(url)
        }
    }

    // MARK: - Status Bar Click Interception

    /// Intercepts clicks on the menu bar status item while a recording or countdown is in progress,
    /// stopping or cancelling immediately in a single click without opening the menu popover.
    private func setupStatusBarClickInterception() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }

            // Only intercept clicks while recording, stopping, or counting down
            guard self.viewModel.isRecording || self.viewModel.state == .stopping || self.viewModel.isCountingDown else {
                return event
            }

            guard let window = event.window, window.className == "NSStatusBarWindow" else {
                return event
            }

            let button = self.statusBarButton ?? self.findStatusBarButton(in: window)
            if self.statusBarButton == nil, let button {
                self.statusBarButton = button
            }

            if let button {
                let locationInButton = button.convert(event.locationInWindow, from: nil)
                guard button.bounds.contains(locationInButton) else {
                    return event
                }
            }

            if self.viewModel.isCountingDown {
                self.logger.info("Status bar button clicked while counting down; cancelling countdown.")
                Task { @MainActor in
                    self.viewModel.cancelCountdown()
                }
            } else if self.viewModel.isRecording {
                self.logger.info("Status bar button clicked while recording; stopping recording immediately.")
                Task { @MainActor in
                    await self.viewModel.stopRecording()
                }
            }

            // Consume the event so the menu does not open
            return nil
        }
    }

    private func findStatusBarButton(in window: NSWindow) -> NSStatusBarButton? {
        findButton(in: window.contentView)
    }

    private func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(in: subview) {
                return button
            }
        }
        return nil
    }

    // MARK: - Keyboard Shortcuts

    private func registerKeyboardShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [viewModel] in
            Task { @MainActor in
                await viewModel.toggleRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .selectContent) { [viewModel] in
            Task { @MainActor in
                viewModel.presentPicker()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .selectArea) { [viewModel] in
            Task { @MainActor in
                await viewModel.presentAreaSelection()
            }
        }

        logger.info("Registered global keyboard shortcuts")
    }

    // MARK: - URL Scheme

    private func handle(_ url: URL) {
        logger.info("Handling URL: \(url.absoluteString)")

        switch url.host {
        case "toggle", "toggle-copy":
            let copyToClipboard = url.host == "toggle-copy"
            Task {
                await viewModel.toggleRecording(copyToClipboard: copyToClipboard)
            }
        case "open-recordings":
            let settings = viewModel.settings
            let didStart = settings.startAccessingOutputDirectory()
            defer {
                if didStart {
                    settings.stopAccessingOutputDirectory()
                }
            }
            NSWorkspace.shared.open(settings.outputDirectory)
        default:
            logger.warning("Unhandled URL host: \(url.host ?? "nil")")
        }
    }
}
