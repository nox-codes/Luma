//
//  EnergyDebugLogger.swift
//  Luma
//
//  Runtime energy profiling — instruments timers, AX callbacks, and notification
//  observers to identify idle wakeup sources.
//
//  HOW TO ACTIVATE
//  ───────────────
//  1. Xcode → Product menu → Scheme → Edit Scheme (or ⌘<)
//  2. Run → Arguments tab → Environment Variables
//  3. Add:  LUMA_ENERGY_DEBUG = 1
//  4. Run a Debug build (Cmd+R)
//  5. Watch the Xcode console — every wakeup source is printed with a timestamp.
//  6. After 30 s idle, copy the console output and paste it for analysis.
//
//  Lines are prefixed:
//    [ED] ⏱ TIMER[label]         — timer callback fired
//    [ED] ♿ AX[notification]     — AX observer notification received
//    [ED] 📣 NOTIF[name]         — NotificationCenter handler invoked
//    [ED] 🔄 REFRESH[sub-call]   — sub-call inside refreshAllPermissions
//
//  High-frequency timers (> 5 Hz) are rate-limited: one summary line per second
//  showing "×N fires". Low-frequency timers log every fire.
//

#if DEBUG
import Foundation

enum EnergyDebugLogger {

    // ─── activation ──────────────────────────────────────────────────────────
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["LUMA_ENERGY_DEBUG"] == "1"

    // ─── timing ──────────────────────────────────────────────────────────────
    private static let sessionStart = Date()
    static func now() -> Double { Date().timeIntervalSince(sessionStart) }

    // ─── rate limiting for high-frequency timers ──────────────────────────────
    // Maps label → (bucket start time, fire count in this bucket)
    private static var timerBuckets: [String: (bucketStart: Double, count: Int)] = [:]

    /// Log a timer callback. For timers faster than `logEveryN` calls/interval,
    /// prints a per-second summary instead of one line per fire.
    ///
    /// - Parameters:
    ///   - label: human-readable name for the timer
    ///   - rateLimit: if > 1, suppress individual fires and print a count every
    ///                time this many fires have accumulated (roughly 1 line/second
    ///                for a 60 fps timer when rateLimit = 60)
    static func timerFired(_ label: String, rateLimit: Int = 1) {
        guard isEnabled else { return }
        let t = now()

        if rateLimit <= 1 {
            print(String(format: "[ED] ⏱ TIMER[\(label)] t=%.3f", t))
            return
        }

        // Accumulate into 1-second buckets and print summary at bucket boundary.
        let (bucketStart, count) = timerBuckets[label] ?? (t, 0)
        let newCount = count + 1
        if t - bucketStart >= 1.0 {
            print(String(format: "[ED] ⏱ TIMER[\(label)] ×\(newCount) fires in last %.1fs  t=%.3f", t - bucketStart, t))
            timerBuckets[label] = (t, 0)
        } else {
            timerBuckets[label] = (bucketStart, newCount)
        }
    }

    // ─── AX observer ─────────────────────────────────────────────────────────
    static func axFired(_ notification: String) {
        guard isEnabled else { return }
        print(String(format: "[ED] ♿ AX[\(notification)] t=%.3f", now()))
    }

    // ─── NotificationCenter ──────────────────────────────────────────────────
    static func notifFired(_ name: String) {
        guard isEnabled else { return }
        print(String(format: "[ED] 📣 NOTIF[\(name)] t=%.3f", now()))
    }

    // ─── refreshAllPermissions sub-calls ─────────────────────────────────────
    static func refreshSubcall(_ label: String) {
        guard isEnabled else { return }
        print(String(format: "[ED] 🔄 REFRESH[\(label)] t=%.3f", now()))
    }
}
#endif
