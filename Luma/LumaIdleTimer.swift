//
//  LumaIdleTimer.swift
//  Luma
//
//  Tracks user inactivity. After `interval` seconds with no interaction,
//  fires `onTimeout`. Any call to `reset()` restarts the countdown.
//  Call `suspend()` to pause the timer without losing the interval value
//  (used during onboarding so the wizard is never hidden mid-flow).
//  Call `resume()` to restart after a suspend.
//
//  Owned by CompanionManager. Thread-safe: all mutations happen on the main queue.
//

import Foundation

@MainActor
final class LumaIdleTimer {

    /// Closure called when the idle interval elapses with no interaction.
    var onTimeout: (() -> Void)?

    private let idleInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private(set) var isSuspended: Bool = false

    init(interval: TimeInterval = 30) {
        self.idleInterval = interval
    }

    // MARK: - Public API

    /// Resets the idle countdown. Call on every user interaction.
    /// If suspended, this is a no-op until `resume()` is called.
    func reset() {
        guard !isSuspended else { return }
        scheduleTimer()
    }

    /// Starts the idle timer from scratch (e.g. when Luma becomes visible).
    func start() {
        guard !isSuspended else { return }
        scheduleTimer()
    }

    /// Stops the idle timer entirely.
    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Suspends the countdown. Use during onboarding.
    func suspend() {
        isSuspended = true
        timer?.cancel()
        timer = nil
    }

    /// Resumes from suspended state and resets the countdown to the full interval.
    func resume() {
        isSuspended = false
        scheduleTimer()
    }

    // MARK: - Private

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil

        let newTimer = DispatchSource.makeTimerSource(queue: .main)
        newTimer.schedule(deadline: .now() + idleInterval)
        newTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.onTimeout?()
        }
        newTimer.resume()
        timer = newTimer
    }
}
