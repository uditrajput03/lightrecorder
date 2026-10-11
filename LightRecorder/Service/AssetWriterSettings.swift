//
//  AssetWriterSettings.swift
//  LightRecorder
//

import AVFoundation
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

/// Builds the `AVAssetWriterInput` output settings for a recording.
@MainActor
enum AssetWriterSettings {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder", category: "AssetWriter")

    /// Builds the video output settings for the selected codec, quality and dynamic range.
    static func video(from settings: SettingsStore, size: CGSize) -> [String: Any] {
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]

        switch settings.videoCodec {
        case .h264:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264
        case .hevc:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
        }

        // Add compression properties for H.264 and HEVC to control bitrate.
        let bpp = settings.videoQuality.bitsPerPixel(for: settings.videoCodec)
        let frameRate = settings.frameRate.effectiveFrameRate
        let bitrate = Int(size.width * size.height * bpp * frameRate)

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: Int(frameRate * 2)
        ]

        videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties

        logger.info(
            "Video compression: \(bitrate / 1_000_000) Mbps at \(Int(frameRate)) fps (\(settings.videoQuality.rawValue) quality)"
        )

        // Standard SDR Rec. 709 color properties for all recordings
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        return videoSettings
    }

    /// Builds the audio output settings shared by the system audio and microphone tracks.
    static func audio(from settings: SettingsStore) -> [String: Any] {
        switch settings.audioCodec {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000
            ]

        case .pcm:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    /// Logs the pixel format, color space, and matrix of an incoming pixel buffer
    /// to help diagnose color formatting issues.
    nonisolated static func logPixelBufferProperties(_ pixelBuffer: CVPixelBuffer) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fourCC = String(format: "%c%c%c%c",
                            (pixelFormat >> 24) & 0xFF,
                            (pixelFormat >> 16) & 0xFF,
                            (pixelFormat >> 8) & 0xFF,
                            pixelFormat & 0xFF)

        let primaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
            as? String ?? "none"
        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)
            as? String ?? "none"
        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
            as? String ?? "none"

        let colorSpaceName: String
        if let cgColorSpace = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue() {
            colorSpaceName = cgColorSpace.name as String? ?? "unnamed"
        } else {
            colorSpaceName = "nil"
        }

        logger.info(
            """
            First frame buffer properties — \
            pixelFormat: \(fourCC) (0x\(String(pixelFormat, radix: 16))), \
            colorPrimaries: \(primaries), \
            transferFunction: \(transfer), \
            yCbCrMatrix: \(matrix), \
            CGColorSpace: \(colorSpaceName)
            """
        )
    }
}
