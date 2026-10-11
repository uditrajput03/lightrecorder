//
//  LightRecorderApp.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import SwiftUI

@main
struct LightRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The recorder lives on the app delegate so URLs can be handled before the
    /// menu bar popover has ever been opened. See ``AppDelegate``.
    private var viewModel: RecorderViewModel { appDelegate.viewModel }

    var body: some Scene {
        // Native macOS .menu style for instant, lag-free interaction
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.menu)

        // Settings window
        Settings {
            SettingsView(settings: viewModel.settings, audioDeviceService: viewModel.audioDeviceService)
        }
    }
}

/// The label shown in the menu bar (icon or duration timer)
struct MenuBarLabel: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        if viewModel.isRecording {
            // Render the duration into a fixed-size image so the
            // NSStatusItem never recalculates its width on each tick.
            if let image = timerImage {
                Image(nsImage: image)
            }
        } else if viewModel.isCountingDown {
            Image(systemName: "timer")
        } else {
            Image(systemName: "record.circle")
        }
    }

    /// Renders the formatted duration into an ``NSImage`` with a stable
    /// width derived from the widest possible string for the current format.
    private var timerImage: NSImage? {
        let text = viewModel.formattedDuration

        let referenceText = viewModel.recordingDuration >= 3600 ? "0:00:00" : "00:00"

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        let referenceSize = (referenceText as NSString).size(withAttributes: attrs)
        let imageSize = NSSize(width: ceil(referenceSize.width), height: ceil(referenceSize.height))

        let textSize = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: (imageSize.width - textSize.width) / 2,
            y: (imageSize.height - textSize.height) / 2
        )

        let image = NSImage(size: imageSize, flipped: false) { _ in
            (text as NSString).draw(at: origin, withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }
}
