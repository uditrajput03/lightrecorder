//
//  AudioLevelMonitor.swift
//  LightRecorder
//
//  Created by Udit Rajput on 11.10.26.
//

import Accelerate
import AVFoundation
import Combine
import OSLog

/// Service that monitors live microphone audio levels for pre-flight testing in Settings.
///
/// Designed to be lightweight and zero-overhead:
/// - Uses `vDSP` (SIMD vector operations) for near-instantaneous RMS/Peak level computation.
/// - Only captures when the Settings Audio tab is active and visible.
/// - Automatically stops on view disappearance to release audio hardware.
@MainActor
final class AudioLevelMonitor: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var level: Float = 0.0
    @Published private(set) var peak: Float = 0.0
    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var permissionDenied: Bool = false

    // MARK: - Private Properties

    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(
        label: "com.lightrecorder.audiomonitor",
        qos: .userInteractive
    )

    private let delegate = AudioLevelSampleDelegate()
    private var displayTimer: Timer?
    private var currentLevel: Float = 0.0
    private var currentPeak: Float = 0.0
    private var peakHoldCounter: Int = 0

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder",
        category: "AudioLevelMonitor"
    )

    // MARK: - Initialization

    init() {
        delegate.onLevels = { [weak self] rawRMS, rawPeak in
            Task { @MainActor [weak self] in
                self?.processIncomingLevels(rms: rawRMS, peak: rawPeak)
            }
        }
    }

    // MARK: - Monitoring Control

    /// Starts live audio level monitoring for the specified device (or default mic if nil)
    func startMonitoring(deviceID: String?) {
        guard !isMonitoring else { return }

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch authStatus {
        case .authorized:
            permissionDenied = false
            startCaptureSession(deviceID: deviceID)
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted {
                    self.permissionDenied = false
                    self.startCaptureSession(deviceID: deviceID)
                } else {
                    self.permissionDenied = true
                }
            }
        case .denied, .restricted:
            permissionDenied = true
            logger.warning("Microphone permission denied; cannot monitor audio levels")
        @unknown default:
            permissionDenied = true
        }
    }

    /// Stops monitoring and releases audio capture hardware
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        displayTimer?.invalidate()
        displayTimer = nil

        currentLevel = 0.0
        currentPeak = 0.0
        level = 0.0
        peak = 0.0

        sampleQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.logger.info("Audio level monitor stopped")
        }
    }

    /// Updates monitoring to a new microphone device
    func switchDevice(to deviceID: String?) {
        if isMonitoring {
            stopMonitoring()
            startMonitoring(deviceID: deviceID)
        }
    }

    // MARK: - Private Methods

    private func startCaptureSession(deviceID: String?) {
        isMonitoring = true

        sampleQueue.async { [weak self] in
            guard let self else { return }

            self.captureSession.beginConfiguration()
            defer { self.captureSession.commitConfiguration() }

            // Clean previous inputs & outputs
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }
            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }

            let device: AVCaptureDevice?
            if let deviceID {
                device = AVCaptureDevice(uniqueID: deviceID)
            } else {
                device = AVCaptureDevice.default(for: .audio)
            }

            guard let device else {
                self.logger.warning("No microphone device available to monitor")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                self.audioOutput.setSampleBufferDelegate(self.delegate, queue: self.sampleQueue)
                if self.captureSession.canAddOutput(self.audioOutput) {
                    self.captureSession.addOutput(self.audioOutput)
                }

                self.captureSession.startRunning()
                self.logger.info("Audio level monitor started for device: \(device.localizedName)")
            } catch {
                self.logger.error("Failed to start audio level monitor: \(error.localizedDescription)")
            }
        }

        // Start ~30 fps UI update timer with ballistics decay
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateBallistics()
            }
        }
    }

    private func processIncomingLevels(rms: Float, peak: Float) {
        // Fast attack
        if rms > currentLevel {
            currentLevel = currentLevel * 0.3 + rms * 0.7
        } else {
            currentLevel = currentLevel * 0.85 + rms * 0.15
        }

        if peak > currentPeak {
            currentPeak = peak
            peakHoldCounter = 15 // Hold peak for ~500ms
        }
    }

    private func updateBallistics() {
        // Smooth release decay
        currentLevel *= 0.92
        if currentLevel < 0.005 {
            currentLevel = 0.0
        }

        if peakHoldCounter > 0 {
            peakHoldCounter -= 1
        } else {
            currentPeak *= 0.90
            if currentPeak < 0.005 {
                currentPeak = 0.0
            }
        }

        level = min(1.0, max(0.0, currentLevel))
        peak = min(1.0, max(0.0, currentPeak))
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

private final class AudioLevelSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    var onLevels: ((Float, Float) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer, totalLength > 0 else { return }

        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = asbd.pointee.mBitsPerChannel

        var rms: Float = 0
        var peak: Float = 0

        if isFloat && bitsPerChannel == 32 {
            let sampleCount = totalLength / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }
            let floatPointer = dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }
            vDSP_rmsqv(floatPointer, 1, &rms, vDSP_Length(sampleCount))
            vDSP_maxmgv(floatPointer, 1, &peak, vDSP_Length(sampleCount))
        } else if !isFloat && bitsPerChannel == 16 {
            let sampleCount = totalLength / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return }
            let int16Pointer = dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }
            var floatSamples = [Float](repeating: 0, count: sampleCount)
            vDSP_vflt16(int16Pointer, 1, &floatSamples, 1, vDSP_Length(sampleCount))
            var divisor: Float = 32768.0
            vDSP_vsdiv(floatSamples, 1, &divisor, &floatSamples, 1, vDSP_Length(sampleCount))
            vDSP_rmsqv(floatSamples, 1, &rms, vDSP_Length(sampleCount))
            vDSP_maxmgv(floatSamples, 1, &peak, vDSP_Length(sampleCount))
        }

        // Convert to decibels with a -50 dB dynamic range floor
        let minDB: Float = -50.0
        let rmsDB = rms > 0.00001 ? 20.0 * log10(rms) : minDB
        let peakDB = peak > 0.00001 ? 20.0 * log10(peak) : minDB

        let normalizedRMS = max(0.0, min(1.0, (rmsDB - minDB) / (-minDB)))
        let normalizedPeak = max(0.0, min(1.0, (peakDB - minDB) / (-minDB)))

        onLevels?(normalizedRMS, normalizedPeak)
    }
}
