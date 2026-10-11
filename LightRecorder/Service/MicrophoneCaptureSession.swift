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
final class MicrophoneCaptureSession: NSObject, @unchecked Sendable {

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(
        label: "com.lightrecorder.microphoneConfigurationQueue",
        qos: .userInitiated
    )
    private let sampleQueue = DispatchQueue(
        label: "com.lightrecorder.microphoneSessionQueue",
        qos: .userInteractive
    )
    private var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    private var isRunning = false
    private var notificationObservers: [NSObjectProtocol] = []
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder",
        category: "MicrophoneCaptureSession"
    )

    override init() {
        super.init()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Starts capturing audio from the specified or default microphone off the main thread.
    func start(deviceID: String?, onSampleBuffer: @escaping (CMSampleBuffer) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    guard !self.isRunning else {
                        continuation.resume()
                        return
                    }
                    self.onSampleBuffer = onSampleBuffer

                    self.session.beginConfiguration()
                    var committed = false
                    defer {
                        if !committed {
                            self.session.commitConfiguration()
                        }
                    }

                    // Remove any existing inputs/outputs
                    for input in self.session.inputs {
                        self.session.removeInput(input)
                    }
                    for output in self.session.outputs {
                        self.session.removeOutput(output)
                    }

                    // Find device
                    let device: AVCaptureDevice?
                    if let deviceID {
                        device = AVCaptureDevice(uniqueID: deviceID)
                    } else {
                        device = AVCaptureDevice.default(for: .audio)
                    }

                    guard let device else {
                        self.logger.warning("No microphone device found")
                        self.session.commitConfiguration()
                        committed = true
                        continuation.resume()
                        return
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else {
                        self.logger.error("Cannot add microphone device input to session")
                        self.session.commitConfiguration()
                        committed = true
                        continuation.resume()
                        return
                    }
                    self.session.addInput(input)

                    self.output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                    guard self.session.canAddOutput(self.output) else {
                        self.logger.error("Cannot add audio data output to session")
                        self.session.commitConfiguration()
                        committed = true
                        continuation.resume()
                        return
                    }
                    self.session.addOutput(self.output)

                    self.session.commitConfiguration()
                    committed = true

                    self.setupNotificationObservers()

                    self.session.startRunning()
                    self.isRunning = true
                    self.logger.info("Microphone capture session started off main thread (device: \(device.localizedName))")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the microphone capture session asynchronously off the main thread.
    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.teardownNotificationObservers()

                guard self.isRunning else {
                    continuation.resume()
                    return
                }

                self.session.stopRunning()
                self.isRunning = false
                self.onSampleBuffer = nil
                self.logger.info("Microphone capture session stopped")
                continuation.resume()
            }
        }
    }

    // MARK: - Notifications

    private func setupNotificationObservers() {
        teardownNotificationObservers()

        let runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.logger.error("AVCaptureSession runtime error: \(error?.localizedDescription ?? "unknown")")
        }
        notificationObservers.append(runtimeErrorObserver)

        let disconnectedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            if let device = notification.object as? AVCaptureDevice,
               device.hasMediaType(.audio) {
                self?.logger.warning("Microphone device disconnected: \(device.localizedName)")
            }
        }
        notificationObservers.append(disconnectedObserver)
    }

    private func teardownNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
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
