//
//  MenuBarView.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import SwiftUI
import ScreenCaptureKit

/// Native macOS menu bar interface for LightRecorder
@MainActor
struct MenuBarView: View {
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject private var settings: SettingsStore
    @AppStorage(ContentSelectionMode.storageKey) private var mode: ContentSelectionMode = .fullScreen

    init(viewModel: RecorderViewModel) {
        self.viewModel = viewModel
        self._settings = ObservedObject(wrappedValue: viewModel.settings)
    }

    var body: some View {
        if viewModel.isRecording {
            recordingMenu
        } else if viewModel.isCountingDown {
            countdownMenu
        } else {
            idleMenu
        }
    }

    // MARK: - Active Recording Menu

    @ViewBuilder
    private var recordingMenu: some View {
        Button("Stop Recording (\(viewModel.formattedDuration))") {
            Task {
                await viewModel.stopRecording()
            }
        }
        .keyboardShortcut("r", modifiers: .command)

        if viewModel.isAreaSelection, let rect = viewModel.selectedSourceRect {
            Text("Target: Area (\(Int(rect.width)) × \(Int(rect.height)))")
        } else {
            Text("Target: Full Screen")
        }

        Divider()

        footerItems
    }

    // MARK: - Active Countdown Menu

    @ViewBuilder
    private var countdownMenu: some View {
        Button("Cancel Countdown") {
            viewModel.cancelCountdown()
        }
        .keyboardShortcut(.escape, modifiers: [])

        Divider()

        footerItems
    }

    // MARK: - Idle Menu

    @ViewBuilder
    private var idleMenu: some View {
        permissionWarningsSection

        captureActionSection

        Divider()

        captureModeSection

        Divider()

        audioSection

        Divider()

        optionsSection

        Divider()

        footerItems
    }

    // MARK: - Menu Sections

    @ViewBuilder
    private var permissionWarningsSection: some View {
        if viewModel.permissionService.screenRecordingState != .granted {
            Button("Grant Screen Recording Permission...") {
                viewModel.permissionService.openScreenRecordingSettings()
            }
            Divider()
        } else if settings.captureMicrophone && viewModel.permissionService.microphoneState != .granted {
            Button("Grant Microphone Permission...") {
                viewModel.permissionService.openMicrophoneSettings()
            }
            Divider()
        }
    }

    @ViewBuilder
    private var captureActionSection: some View {
        Button("Start Recording") {
            Task {
                await startRecording()
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!viewModel.canStartRecording)
    }

    @ViewBuilder
    private var captureModeSection: some View {
        Toggle("Full Screen", isOn: Binding(
            get: { mode == .fullScreen && !viewModel.isAreaSelection },
            set: { _ in
                mode = .fullScreen
                Task {
                    await viewModel.selectFullScreen()
                }
            }
        ))
        .keyboardShortcut("1", modifiers: .command)

        Toggle(viewModel.isAreaSelection ? "Change Selected Area..." : "Select Area...", isOn: Binding(
            get: { viewModel.isAreaSelection },
            set: { _ in
                mode = .selectArea
                Task {
                    await viewModel.presentAreaSelection()
                }
            }
        ))
        .keyboardShortcut("2", modifiers: .command)

        if #available(macOS 14.0, *) {
            Toggle("Select Window / App...", isOn: Binding(
                get: { mode == .pickContent && viewModel.hasContentSelected && !viewModel.isAreaSelection },
                set: { _ in
                    mode = .pickContent
                    viewModel.presentPicker()
                }
            ))
            .keyboardShortcut("3", modifiers: .command)
        }

        if viewModel.hasContentSelected {
            Button("Reset Selection") {
                Task {
                    await viewModel.resetSelection()
                }
            }
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        Toggle("Capture Microphone", isOn: $settings.captureMicrophone)

        if settings.captureMicrophone && !viewModel.audioDeviceService.availableDevices.isEmpty {
            Menu("Microphone Source") {
                Picker("Microphone Source", selection: $settings.selectedMicrophoneID) {
                    Text("System Default").tag(Optional<String>.none)
                    ForEach(viewModel.audioDeviceService.availableDevices) { device in
                        Text(device.name).tag(Optional<String>.some(device.id))
                    }
                }
                .pickerStyle(.inline)
            }
        }

        Toggle("Capture System Audio", isOn: $settings.captureSystemAudio)
    }

    @ViewBuilder
    private var optionsSection: some View {
        Menu("Quick Options") {
            Toggle("Show Cursor", isOn: $settings.showCursor)

            Picker("Countdown", selection: $settings.countdownDuration) {
                ForEach(CountdownDuration.allCases) { duration in
                    Text(duration.displayName).tag(duration)
                }
            }
            .pickerStyle(.inline)

            Picker("Frame Rate", selection: $settings.frameRate) {
                ForEach(FrameRate.allCases) { rate in
                    Text(rate.displayName).tag(rate)
                }
            }
            .pickerStyle(.inline)
        }
    }

    @ViewBuilder
    private var footerItems: some View {
        Button("Open Recordings Folder") {
            openRecordingsFolder()
        }

        Button("Settings...") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit LightRecorder") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Actions

    private func startRecording() async {
        if mode == .fullScreen && !viewModel.hasContentSelected {
            await viewModel.selectFullScreen()
        }
        await viewModel.startRecording()
    }

    private func openRecordingsFolder() {
        let didStart = settings.startAccessingOutputDirectory()
        defer {
            if didStart {
                settings.stopAccessingOutputDirectory()
            }
        }
        NSWorkspace.shared.open(settings.outputDirectory)
    }

    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
