//
//  SettingsStore.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import Foundation

/// Video codec options for recording
enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "H.265"

    var id: String { rawValue }

    /// Whether this codec supports user-adjustable quality/bitrate settings.
    var supportsQualitySetting: Bool {
        true
    }
}

/// Container format for output files
enum ContainerFormat: String, CaseIterable, Identifiable {
    case mov
    case mp4

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    /// Video codecs supported by this container format
    var supportedVideoCodecs: [VideoCodec] {
        VideoCodec.allCases
    }



    /// Audio codecs supported by this container format
    var supportedAudioCodecs: [AudioCodec] {
        switch self {
        case .mov:
            // MOV supports all audio codecs
            return AudioCodec.allCases
        case .mp4:
            // MP4 only supports AAC (not raw PCM)
            return [.aac]
        }
    }
}

/// Audio codec options
enum AudioCodec: String, CaseIterable, Identifiable {
    case aac = "AAC"
    case pcm = "PCM"

    var id: String { rawValue }
}

/// Frame rate options for recording
enum FrameRate: Int, CaseIterable, Identifiable {
    case native = 0
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .native:
            return "Native"
        default:
            return "\(rawValue) fps"
        }
    }

    /// The frame rate in Hz the recording is captured and written at.
    ///
    /// For explicit rates this returns the selected value. `.native` resolves to
    /// 60: ScreenCaptureKit only delivers frames when content changes, so a
    /// higher ceiling produced a heavily variable frame rate that broke
    /// concatenation and upload tools without adding useful frames.
    ///
    /// `CaptureEngine` uses this for `minimumFrameInterval`, `AssetWriter` uses it
    /// as the constant frame rate grid, and both use it for the bitrate budget.
    var effectiveFrameRate: Double {
        switch self {
        case .native: return 60.0
        default:      return Double(rawValue)
        }
    }
}

/// Video quality presets controlling compression bitrate for H.264 and HEVC.
///
/// Each preset defines a bits-per-pixel multiplier used to calculate the
/// target average bitrate: `width * height * bpp * frameRate`.
enum VideoQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }

    /// Bits-per-pixel multiplier for H.264
    var h264BitsPerPixel: Double {
        switch self {
        case .low:    return 0.04
        case .medium: return 0.2
        case .high:   return 0.6
        }
    }

    /// Bits-per-pixel multiplier for HEVC (more efficient codec)
    var hevcBitsPerPixel: Double {
        switch self {
        case .low:    return 0.02
        case .medium: return 0.15
        case .high:   return 0.4
        }
    }

    /// Returns the bits-per-pixel multiplier for the given codec
    func bitsPerPixel(for codec: VideoCodec) -> Double {
        switch codec {
        case .h264: return h264BitsPerPixel
        case .hevc: return hevcBitsPerPixel
        }
    }
}

import Combine

/// Persists user preferences using UserDefaults
@MainActor
final class SettingsStore: ObservableObject {

    private func mutate(_ block: () -> Void) {
        objectWillChange.send()
        block()
    }

    // MARK: - Dependencies

    private let defaults: UserDefaults

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Video Settings

    var frameRate: FrameRate {
        get {
            FrameRate(rawValue: frameRateRaw) ?? .fps60
        }
        set {
            frameRateRaw = newValue.rawValue
        }
    }

    var videoQuality: VideoQuality {
        get {
            VideoQuality(rawValue: videoQualityRaw) ?? .medium
        }
        set {
            videoQualityRaw = newValue.rawValue
        }
    }

    var videoCodec: VideoCodec {
        get {
            VideoCodec(rawValue: videoCodecRaw) ?? .hevc
        }
        set {
            videoCodecRaw = newValue.rawValue
        }
    }

    var containerFormat: ContainerFormat {
        get {
            ContainerFormat(rawValue: containerFormatRaw) ?? .mov
        }
        set {
            containerFormatRaw = newValue.rawValue

            // Ensure current audio codec is compatible with new container
            if !newValue.supportedAudioCodecs.contains(audioCodec) {
                audioCodec = .aac
            }
        }
    }

    var captureNativeResolution: Bool {
        get {
            defaults.object(forKey: "captureNativeResolution") as? Bool ?? true
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "captureNativeResolution")
            }
        }
    }


    // MARK: - Audio Settings

    var captureMicrophone: Bool {
        get {
            defaults.bool(forKey: "captureMicrophone")
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "captureMicrophone")
            }
        }
    }

    var captureSystemAudio: Bool {
        get {
            defaults.object(forKey: "captureSystemAudio") as? Bool ?? true
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "captureSystemAudio")
            }
        }
    }

    var audioCodec: AudioCodec {
        get {
            AudioCodec(rawValue: audioCodecRaw) ?? .aac
        }
        set {
            // Ensure the audio codec is compatible with the current container format
            guard containerFormat.supportedAudioCodecs.contains(newValue) else {
                // If codec is not compatible, switch to MOV container first
                containerFormatRaw = ContainerFormat.mov.rawValue
                audioCodecRaw = newValue.rawValue
                return
            }

            audioCodecRaw = newValue.rawValue
        }
    }

    var selectedMicrophoneID: String? {
        get {
            defaults.string(forKey: "selectedMicrophoneID")
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "selectedMicrophoneID")
            }
        }
    }

    // MARK: - Content Filter Settings

    var showCursor: Bool {
        get {
            defaults.object(forKey: "showCursor") as? Bool ?? true
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "showCursor")
            }
        }
    }

    var showWallpaper: Bool {
        get {
            defaults.object(forKey: "showWallpaper") as? Bool ?? true
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "showWallpaper")
            }
        }
    }

    var showMenuBar: Bool {
        get {
            defaults.object(forKey: "showMenuBar") as? Bool ?? true
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "showMenuBar")
            }
        }
    }

    var showDock: Bool {
        get {
            defaults.object(forKey: "showDock") as? Bool ?? true
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "showDock")
            }
        }
    }

    var showWindowShadows: Bool {
        get {
            defaults.object(forKey: "showWindowShadows") as? Bool ?? true
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "showWindowShadows")
            }
        }
    }

    var showLightRecorder: Bool {
        get {
            defaults.object(forKey: "showLightRecorder") as? Bool ?? false
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "showLightRecorder")
            }
        }
    }

    // MARK: - Output Settings

    /// The default output directory (Movies/LightRecorder)
    var defaultOutputDirectory: URL {
        URL.homeDirectory.appending(path: "Movies/LightRecorder")
    }

    /// Security-scoped bookmark data for the custom output directory
    private var customOutputDirectoryBookmark: Data? {
        get {
            defaults.data(forKey: "customOutputDirectoryBookmark")
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "customOutputDirectoryBookmark")
            }
        }
    }

    /// Whether a custom output directory has been set
    var hasCustomOutputDirectory: Bool {
        customOutputDirectoryBookmark != nil
    }

    /// The current output directory, using custom path if set
    var outputDirectory: URL {
        guard let bookmarkData = customOutputDirectoryBookmark else {
            return defaultOutputDirectory
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Bookmark is stale, try to recreate it
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let newBookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        customOutputDirectoryBookmark = newBookmark
                    }
                }
            }

            return url
        } catch {
            // If bookmark resolution fails, fall back to default
            return defaultOutputDirectory
        }
    }

    /// Sets a custom output directory from a user-selected URL
    /// - Parameter url: The URL selected by the user via NSOpenPanel
    func setCustomOutputDirectory(_ url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            customOutputDirectoryBookmark = bookmarkData
        } catch {
            if let bookmarkData = try? url.bookmarkData() {
                customOutputDirectoryBookmark = bookmarkData
            }
        }
    }

    /// Resets to the default output directory
    func resetOutputDirectory() {
        customOutputDirectoryBookmark = nil
    }

    /// Starts accessing the security-scoped output directory resource
    /// Call this before writing files to a custom output directory
    /// - Returns: Whether access was successfully started (always true for default directory)
    func startAccessingOutputDirectory() -> Bool {
        guard customOutputDirectoryBookmark != nil else {
            return true // Default directory doesn't need security scope
        }
        return outputDirectory.startAccessingSecurityScopedResource()
    }

    /// Stops accessing the security-scoped output directory resource
    func stopAccessingOutputDirectory() {
        guard customOutputDirectoryBookmark != nil else {
            return // Default directory doesn't need security scope
        }
        outputDirectory.stopAccessingSecurityScopedResource()
    }

    // MARK: - Private Storage

    private var frameRateRaw: Int {
        get {
            guard defaults.object(forKey: "frameRate") != nil else {
                return FrameRate.fps60.rawValue
            }
            return defaults.integer(forKey: "frameRate")
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "frameRate")
            }
        }
    }

    private var videoQualityRaw: String {
        get {
            defaults.string(forKey: "videoQuality") ?? VideoQuality.medium.rawValue
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "videoQuality")
            }
        }
    }

    private var videoCodecRaw: String {
        get {
            defaults.string(forKey: "videoCodec") ?? VideoCodec.hevc.rawValue
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "videoCodec")
            }
        }
    }

    private var containerFormatRaw: String {
        get {
            defaults.string(forKey: "containerFormat") ?? ContainerFormat.mov.rawValue
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "containerFormat")
            }
        }
    }

    private var audioCodecRaw: String {
        get {
            defaults.string(forKey: "audioCodec") ?? AudioCodec.aac.rawValue
        }
        set {
            mutate {
                defaults.set(newValue, forKey: "audioCodec")
            }
        }
    }

    // MARK: - Helper Methods

    /// Generates a filename based on the current timestamp
    func generateFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        return "LightRecorder_\(timestamp).\(containerFormat.fileExtension)"
    }

    /// Returns the full output URL for a new recording
    func generateOutputURL() -> URL {
        outputDirectory.appending(path: generateFilename())
    }
}
