//
//  CountdownOverlay.swift
//  LightRecorder
//
//  Created by Udit Rajput on 11.10.26.
//

import AppKit
import SwiftUI
import OSLog

/// State object driving the animated countdown HUD view
@MainActor
final class CountdownState: ObservableObject {
    @Published var remaining: Int
    var onCancel: () -> Void

    init(remaining: Int, onCancel: @escaping () -> Void) {
        self.remaining = remaining
        self.onCancel = onCancel
    }
}

/// SwiftUI view rendered inside the countdown overlay panel
struct CountdownView: View {
    @ObservedObject var state: CountdownState

    var body: some View {
        VStack(spacing: 6) {
            Text("\(state.remaining)")
                .font(.system(size: 84, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 10, x: 0, y: 3)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.remaining)

            Button(action: state.onCancel) {
                Text("esc to cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 1)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 160, height: 140)
    }
}

/// A non-activating floating panel used for the countdown display
final class CountdownPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Manages presenting and dismissing an animated countdown timer HUD before recording starts
@MainActor
final class CountdownOverlay {

    // MARK: - Properties

    private var panel: CountdownPanel?
    private var isCancelled = false
    private var activeCountdownTask: Task<Void, Error>?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LightRecorder",
        category: "CountdownOverlay"
    )

    // MARK: - Public Methods

    /// Presents a countdown HUD centered in the target rectangle on screen.
    /// - Parameters:
    ///   - seconds: The initial countdown value (e.g. 3, 5)
    ///   - rect: The target capture rect in NSScreen coordinates
    ///   - screen: The NSScreen on which capture will occur
    /// - Returns: `true` if countdown completed successfully, `false` if cancelled.
    func startCountdown(seconds: Int, in rect: CGRect, on screen: NSScreen) async -> Bool {
        dismiss()
        isCancelled = false

        guard seconds > 0 else { return true }

        let hudWidth: CGFloat = 160
        let hudHeight: CGFloat = 140
        let centerPoint: CGPoint
        if rect.width > 50 && rect.height > 50 {
            centerPoint = CGPoint(x: rect.midX, y: rect.midY)
        } else {
            centerPoint = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        }

        let hudRect = NSRect(
            x: centerPoint.x - hudWidth / 2,
            y: centerPoint.y - hudHeight / 2,
            width: hudWidth,
            height: hudHeight
        )

        let panel = CountdownPanel(contentRect: hudRect)
        panel.onCancel = { [weak self] in
            self?.cancel()
        }

        let countdownState = CountdownState(remaining: seconds) { [weak self] in
            self?.cancel()
        }

        let hostingView = NSHostingView(rootView: CountdownView(state: countdownState))
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        let eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }

        defer {
            activeCountdownTask?.cancel()
            activeCountdownTask = nil
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            dismiss()
        }

        logger.info("Started countdown: \(seconds)s")

        for current in stride(from: seconds, through: 1, by: -1) {
            if isCancelled {
                logger.info("Countdown was cancelled at \(current)s")
                return false
            }
            countdownState.remaining = current
            do {
                let sleepTask = Task {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                activeCountdownTask = sleepTask
                try await sleepTask.value
                activeCountdownTask = nil
            } catch {
                return false
            }
        }

        if isCancelled {
            return false
        }

        logger.info("Countdown completed successfully")
        return true
    }

    /// Cancels any active countdown
    func cancel() {
        isCancelled = true
        activeCountdownTask?.cancel()
        activeCountdownTask = nil
        dismiss()
    }

    /// Dismisses the countdown HUD panel
    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
