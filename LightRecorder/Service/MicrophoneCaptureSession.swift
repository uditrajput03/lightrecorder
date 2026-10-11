//
//  MicrophoneCaptureSession.swift
//  LightRecorder
//
//  Created by Udit Rajput on 11.10.26.
//

import AVFoundation
import OSLog

/// A lightweight microphone capture session using AVCaptureSession.
/// Used on macOS 13 and 14 where ScreenCaptureKit's native microphone streaming
/// (SCStreamOutputType.microphone, introduced in macOS 15) is not available.
final class MicrophoneCaptureSession: NSObject {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(
        label: "com.lightrecorder.microphoneSessionQueue",
        qos: .userInteractive
    )
    private var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    private var isRunning = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder",
        category: "MicrophoneCaptureSession"
    )

    override init() {
        super.init()
    }

    /// Starts capturing audio from the specified or default microphone
    func start(deviceID: String?, onSampleBuffer: @escaping (CMSampleBuffer) -> Void) throws {
        guard !isRunning else { return }
        self.onSampleBuffer = onSampleBuffer

        session.beginConfiguration()
        var committed = false
        defer {
            if !committed {
                session.commitConfiguration()
            }
        }

        // Remove any existing inputs/outputs
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        // Find device
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let device else {
            logger.warning("No microphone device found")
            return
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            logger.error("Cannot add microphone device input to session")
            return
        }
        session.addInput(input)

        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            logger.error("Cannot add audio data output to session")
            return
        }
        session.addOutput(output)

        session.commitConfiguration()
        committed = true

        session.startRunning()
        isRunning = true
        logger.info("Microphone capture session started (device: \(device.localizedName))")
    }

    /// Stops the microphone capture session
    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
        onSampleBuffer = nil
        logger.info("Microphone capture session stopped")
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicrophoneCaptureSession: AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}
