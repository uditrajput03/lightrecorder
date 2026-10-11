//
//  SettingsView.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 28.03.26.
//

import KeyboardShortcuts
import SwiftUI

/// The settings window for LightRecorder
@MainActor
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var audioDeviceService: AudioDeviceService

    init(settings: SettingsStore, audioDeviceService: AudioDeviceService) {
        self.settings = settings
        self.audioDeviceService = audioDeviceService
    }

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

            AudioSettingsView(settings: settings, audioDeviceService: audioDeviceService)
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
        switch settings.videoCodec {
        case .hevc:
            return "Bitrate presets: Low (~8 Mbps), Medium (~16 Mbps), High (~28 Mbps)"
        case .h264:
            return "Quality factor presets: Low (0.5), Medium (0.75), High (1.0)"
        }
    }

    private var captureNativeResHelpText: String {
        """
        When enabled, captures at physical pixel resolution (2x on Retina displays).
        When disabled, captures at points resolution (1x).
        """
    }

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

                Toggle("Crash-Resilient Recording (Fragmented MP4)", isOn: $settings.crashResilientRecording)
                    .help("Writes periodic movie fragments so the recording survives unexpected app termination or power loss. May reduce compatibility with certain video editors.")
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
    @ObservedObject var audioDeviceService: AudioDeviceService
    @StateObject private var audioMonitor = AudioLevelMonitor()

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Capture System Audio", isOn: $settings.captureSystemAudio)
                    .help("Record audio from applications and system sounds")

                Toggle("Capture Microphone", isOn: $settings.captureMicrophone)
                    .help("Record audio from the microphone")

                if settings.captureMicrophone {
                    if audioDeviceService.availableDevices.isEmpty {
                        Text("No microphones detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Microphone Device", selection: $settings.selectedMicrophoneID) {
                            Text("System Default").tag(Optional<String>.none)
                            ForEach(audioDeviceService.availableDevices) { device in
                                Text(device.name).tag(Optional<String>.some(device.id))
                            }
                        }
                        .help("Select which microphone input to record")

                        if audioMonitor.permissionDenied {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                Text("Microphone permission required for level test")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        } else {
                            AudioLevelMeterView(level: audioMonitor.level, peak: audioMonitor.peak)
                                .padding(.top, 4)
                        }
                    }
                }
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
        .onAppear {
            if settings.captureMicrophone {
                audioMonitor.startMonitoring(deviceID: settings.selectedMicrophoneID)
            }
        }
        .onDisappear {
            audioMonitor.stopMonitoring()
        }
        .onChange(of: settings.captureMicrophone) { enabled in
            if enabled {
                audioMonitor.startMonitoring(deviceID: settings.selectedMicrophoneID)
            } else {
                audioMonitor.stopMonitoring()
            }
        }
        .onChange(of: settings.selectedMicrophoneID) { newID in
            audioMonitor.switchDevice(to: newID)
        }
    }
}

// MARK: - Pre-Flight Audio Level Meter View

struct AudioLevelMeterView: View {
    let level: Float
    let peak: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Input Level")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if level > 0.05 {
                    Text("Speaking")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    // Meter background track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 7)

                    // Active signal gradient bar
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, width * CGFloat(level)), height: 7)
                        .animation(.linear(duration: 0.04), value: level)

                    // Peak hold tick mark
                    if peak > 0.02 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.85))
                            .frame(width: 2, height: 9)
                            .offset(x: min(width - 2, width * CGFloat(peak)))
                    }
                }
            }
            .frame(height: 9)
        }
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
            Section("Recording") {
                Picker("Countdown Timer", selection: $settings.countdownDuration) {
                    ForEach(CountdownDuration.allCases) { duration in
                        Text(duration.displayName).tag(duration)
                    }
                }
                .help("Delay before recording begins to let you prepare")
            }

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
    @MainActor
    static var previews: some View {
        SettingsView(settings: SettingsStore(), audioDeviceService: AudioDeviceService())
    }
}
