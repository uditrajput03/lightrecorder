//
//  SettingsView.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

/// The settings window for LightRecorder
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(0)

            VideoSettingsView(settings: settings)
                .tabItem {
                    Label("Video", systemImage: "video")
                }
                .tag(1)

            AudioSettingsView(settings: settings)
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }
                .tag(2)

            ShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(3)
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section("Recording") {
                KeyboardShortcuts.Recorder("Toggle Recording", name: .toggleRecording)
            }

            Section("Content Selection") {
                KeyboardShortcuts.Recorder("Select Content", name: .selectContent)
                KeyboardShortcuts.Recorder("Select Area", name: .selectArea)
            }

            Section {
                Text("Shortcuts work globally, even when LightRecorder is not focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Video Settings

struct VideoSettingsView: View {
    @ObservedObject var settings: SettingsStore


    private var qualityHelpText: String {
        "Controls the video bitrate. Higher quality produces sharper output with larger files"
    }

    private let captureNativeResHelpText = """
        When enabled, captures at the display's native pixel resolution. \
        When disabled, captures at the logical (1x) resolution. Has no effect on non-Retina displays
        """

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Frame Rate", selection: $settings.frameRate) {
                    ForEach(FrameRate.allCases) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }

                Picker("Codec", selection: $settings.videoCodec) {
                    ForEach(VideoCodec.allCases) { codec in
                        let isSupported = settings.containerFormat.supportedVideoCodecs.contains(codec)
                        if isSupported {
                            Text(codec.rawValue).tag(codec)
                        } else {
                            Text("\(codec.rawValue) (not supported for \(settings.containerFormat.rawValue.uppercased()))")
                                .foregroundStyle(.secondary)
                                .tag(codec)
                        }
                    }
                }

                Picker("Container", selection: $settings.containerFormat) {
                    ForEach(ContainerFormat.allCases) { format in
                        Text(".\(format.rawValue)").tag(format)
                    }
                }

                Picker("Quality", selection: $settings.videoQuality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .disabled(!settings.videoCodec.supportsQualitySetting)
                .help(qualityHelpText)
            }

            Section("Advanced") {
                Toggle("Native Resolution", isOn: $settings.captureNativeResolution)
                    .help(captureNativeResHelpText)
            }

            Section("Display Elements") {
                Toggle("Show Cursor", isOn: $settings.showCursor)
                Toggle("Show Wallpaper", isOn: $settings.showWallpaper)
                Toggle("Show Menu Bar", isOn: $settings.showMenuBar)
                Toggle("Show Dock", isOn: $settings.showDock)
                Toggle("Show LightRecorder", isOn: $settings.showLightRecorder)
            }

            Section("Window Capture") {
                Toggle("Show Window Shadows", isOn: $settings.showWindowShadows)
                    .help("Include window shadows when capturing individual windows")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Audio Settings

struct AudioSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Capture System Audio", isOn: $settings.captureSystemAudio)
                    .help("Record audio from applications and system sounds")

                Toggle("Capture Microphone", isOn: $settings.captureMicrophone)
                    .help("Record audio from the default microphone input")
            }

            Section("Format") {
                Picker("Codec", selection: $settings.audioCodec) {
                    ForEach(AudioCodec.allCases) { codec in
                        let isSupported = settings.containerFormat.supportedAudioCodecs.contains(codec)
                        if isSupported {
                            Text(codec.rawValue).tag(codec)
                        } else {
                            Text("\(codec.rawValue) (not supported for \(settings.containerFormat.rawValue.uppercased()))")
                                .foregroundStyle(.secondary)
                                .tag(codec)
                        }
                    }
                }
                .help("AAC is compressed, PCM is uncompressed lossless (MOV only)")
            }

            Section {
                Text("Audio tracks are recorded separately for post-processing flexibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// Formats the output directory path for display
    private var displayPath: String {
        let path = settings.outputDirectory.path(percentEncoded: false)
        // Replace home directory with ~ for cleaner display
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var body: some View {
        Form {
            Section("Output Location") {
                LabeledContent {
                    HStack {
                        Button("Change...") {
                            selectOutputDirectory()
                        }

                        if settings.hasCustomOutputDirectory {
                            Button("Reset", role: .destructive) {
                                settings.resetOutputDirectory()
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(displayPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            AboutSection()
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Opens an NSOpenPanel to select a custom output directory
    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select Output Directory"
        panel.message = "Choose where recordings will be saved"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory

        if panel.runModal() == .OK, let url = panel.url {
            settings.setCustomOutputDirectory(url)
        }
    }
}

// MARK: - About Section

struct AboutSection: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var gitSHA: String {
        Bundle.main.infoDictionary?["GitSHA"] as? String ?? "dev"
    }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: "v\(appVersion) (\(gitSHA))")

            if let websiteURL = URL(string: "https://uditrajput03.github.io/lightrecorder") {
                LabeledContent("Website") {
                    Link("uditrajput03.github.io/lightrecorder", destination: websiteURL)
                }
            }

            if let sourceURL = URL(string: "https://github.com/uditrajput03/lightrecorder") {
                LabeledContent("Source Code") {
                    Link("github.com/uditrajput03/lightrecorder", destination: sourceURL)
                }
            }
        }
    }
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(settings: SettingsStore())
    }
}
