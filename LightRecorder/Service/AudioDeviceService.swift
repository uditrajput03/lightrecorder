//
//  AudioDeviceService.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 02.02.26.
//

import AVFoundation
import OSLog

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

import Combine

/// Service for enumerating and monitoring available microphone devices
@MainActor
final class AudioDeviceService: ObservableObject {

    // MARK: - Properties

    private var hasLoadedDevices = false
    @Published private var _availableDevices: [AudioInputDevice] = []

    var availableDevices: [AudioInputDevice] {
        if !hasLoadedDevices {
            hasLoadedDevices = true
            loadDevices()
        }
        return _availableDevices
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder",
        category: "AudioDeviceService"
    )

    // MARK: - Initialization

    init() {
        setupNotifications()
        hasLoadedDevices = true
        loadDevices()
    }

    // MARK: - Public Methods

    /// Refreshes the list of available audio input devices
    func refreshDevices() {
        hasLoadedDevices = true
        loadDevices()
    }

    private func loadDevices() {
        let devices: [AVCaptureDevice]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        devices = discovery.devices

        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID

        _availableDevices = devices.map { device in
            AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID
            )
        }

        logger.info("Found \(self._availableDevices.count) audio input devices (default: \(defaultID ?? "none"))")
    }

    // MARK: - Private Methods

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
                self?.logger.info("Audio device connected")
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
                self?.logger.info("Audio device disconnected")
            }
        }
    }
}
