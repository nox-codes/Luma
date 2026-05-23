//
//  LumaMouseWiggleDetector.swift
//  Luma
//
//  Detects the rapid side-to-side mouse shake gesture that Apple uses to
//  temporarily enlarge the cursor ("shake to find cursor"). When a wiggle is
//  detected, Luma either wakes up its cursor overlay (if hidden) or resets the
//  idle timer (if already visible).
//
//  Strategy: poll NSEvent.mouseLocation at ~30 fps, accumulate samples in a
//  400 ms rolling window, then look for ≥3 X-axis direction reversals at an
//  average speed ≥ 500 pts/sec — the same rough heuristics Apple uses.
//  A 2-second cooldown prevents the callback from firing multiple times for
//  a single shake.
//

import AppKit
import Foundation

@MainActor
final class LumaMouseWiggleDetector {

    /// Called on the main actor when a wiggle gesture is confirmed.
    var onWiggleDetected: (() -> Void)?

    private var pollTimer: Timer?

    /// A single timestamped mouse position reading.
    private struct MousePositionSample {
        let position: CGPoint
        let timestamp: TimeInterval
    }
    private var recentPositionSamples: [MousePositionSample] = []

    /// Timestamp of the last confirmed wiggle, used to enforce the cooldown.
    private var lastWiggleDetectionTime: TimeInterval = 0

    // MARK: - Tuning Constants

    /// How long (seconds) to keep position samples for analysis.
    private let wiggleSampleWindowDuration: TimeInterval = 0.4

    /// Minimum average mouse speed (pts/sec) required to count as a wiggle.
    /// Below this the user is just moving normally, not shaking.
    private let minimumWiggleSpeedThreshold: CGFloat = 500

    /// How many X-axis direction reversals must occur within the sample window.
    private let minimumDirectionReversalsRequired: Int = 3

    /// Require at least this many samples before running analysis.
    /// At 30 fps over 400 ms that's ~12 samples max; 8 ensures a real window.
    private let minimumSamplesRequiredForAnalysis: Int = 8

    /// Seconds to wait before allowing the wiggle callback to fire again.
    private let wiggleDetectionCooldownDuration: TimeInterval = 2.0

    /// Minimum per-sample X velocity (pts/sec) to count as intentional — filters out
    /// tiny jitter that would otherwise produce false direction-reversal counts.
    private let minimumIntentionalVelocityThreshold: CGFloat = 10

    // MARK: - Public API

    /// Begin polling for wiggle gestures. Safe to call multiple times — only one
    /// timer runs at a time.
    func start() {
        guard pollTimer == nil else { return }
        // 30 fps gives ~12 samples per 400 ms window — enough resolution to catch
        // the direction reversals in a real shake without hammering the CPU.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordSampleAndAnalyzeWiggle()
            }
        }
        LumaLogger.log("[LumaMouseWiggleDetector] Polling started")
    }

    /// Stop polling and discard all buffered samples.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        recentPositionSamples.removeAll()
        LumaLogger.log("[LumaMouseWiggleDetector] Polling stopped")
    }

    // MARK: - Private

    private func recordSampleAndAnalyzeWiggle() {
        let currentMousePosition = NSEvent.mouseLocation
        let currentTime = CACurrentMediaTime()

        recentPositionSamples.append(MousePositionSample(position: currentMousePosition, timestamp: currentTime))

        // Evict samples that have aged out of the rolling analysis window.
        recentPositionSamples = recentPositionSamples.filter {
            currentTime - $0.timestamp <= wiggleSampleWindowDuration
        }

        // Can't analyze meaningfully with too few samples.
        guard recentPositionSamples.count >= minimumSamplesRequiredForAnalysis else { return }

        // Respect the cooldown so a single shake only fires the callback once.
        guard currentTime - lastWiggleDetectionTime >= wiggleDetectionCooldownDuration else { return }

        // ── Velocity analysis ─────────────────────────────────────────────────────
        // Compute per-interval X-axis velocities between consecutive samples.
        var xAxisVelocities: [CGFloat] = []
        for sampleIndex in 1..<recentPositionSamples.count {
            let deltaX = recentPositionSamples[sampleIndex].position.x
                       - recentPositionSamples[sampleIndex - 1].position.x
            let deltaTime = recentPositionSamples[sampleIndex].timestamp
                          - recentPositionSamples[sampleIndex - 1].timestamp
            if deltaTime > 0 {
                xAxisVelocities.append(deltaX / CGFloat(deltaTime))
            }
        }

        // Count sign changes (direction reversals) in X velocity, skipping near-zero
        // values that are just positioning noise rather than intentional movement.
        var xDirectionReversalCount = 0
        for velocityIndex in 1..<xAxisVelocities.count {
            let previousVelocity = xAxisVelocities[velocityIndex - 1]
            let currentVelocity  = xAxisVelocities[velocityIndex]
            let previousIsIntentional = abs(previousVelocity) > minimumIntentionalVelocityThreshold
            let currentIsIntentional  = abs(currentVelocity)  > minimumIntentionalVelocityThreshold
            if previousIsIntentional && currentIsIntentional && previousVelocity * currentVelocity < 0 {
                xDirectionReversalCount += 1
            }
        }

        // Compute average travel speed over the sample window.
        var totalTravelDistance: CGFloat = 0
        for sampleIndex in 1..<recentPositionSamples.count {
            let deltaX = recentPositionSamples[sampleIndex].position.x
                       - recentPositionSamples[sampleIndex - 1].position.x
            let deltaY = recentPositionSamples[sampleIndex].position.y
                       - recentPositionSamples[sampleIndex - 1].position.y
            totalTravelDistance += sqrt(deltaX * deltaX + deltaY * deltaY)
        }
        let totalTimeSpan = recentPositionSamples.last!.timestamp - recentPositionSamples.first!.timestamp
        let averageMouseSpeed = totalTimeSpan > 0 ? totalTravelDistance / CGFloat(totalTimeSpan) : 0

        // ── Gate check ────────────────────────────────────────────────────────────
        guard xDirectionReversalCount >= minimumDirectionReversalsRequired else { return }
        guard averageMouseSpeed >= minimumWiggleSpeedThreshold else { return }

        // Confirmed wiggle — record time, flush samples to prevent immediate re-fire.
        lastWiggleDetectionTime = currentTime
        recentPositionSamples.removeAll()

        LumaLogger.log(
            "[LumaMouseWiggleDetector] Wiggle detected — \(xDirectionReversalCount) reversals, " +
            "avg speed: \(Int(averageMouseSpeed)) pts/s"
        )
        onWiggleDetected?()
    }
}
