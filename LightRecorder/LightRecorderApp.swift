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

/// The label shown in the menu bar (stop icon during recording, timer during countdown, record circle when idle)
struct MenuBarLabel: View {
    @ObservedObject var viewModel: RecorderViewModel

    var body: some View {
        if viewModel.isRecording || viewModel.state == .stopping {
            Image(systemName: "stop.circle.fill")
        } else if viewModel.isCountingDown {
            Image(systemName: "timer")
        } else {
            Image(systemName: "record.circle")
        }
    }
}
