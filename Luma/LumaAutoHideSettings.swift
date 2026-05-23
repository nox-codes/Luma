//
//  LumaAutoHideSettings.swift
//  Luma
//
//  Defines the user-configurable auto-hide timeout options for Luma's cursor
//  overlay. The selected interval is persisted in UserDefaults so it survives
//  app restarts and is read by CompanionManager to drive LumaIdleTimer.
//

import Foundation

/// The available auto-hide timeout durations a user can choose for Luma's cursor overlay.
/// A raw value of 0 means "Never" — the idle timer is disabled entirely.
enum LumaAutoHideInterval: Double, CaseIterable, Identifiable {
    case fifteenSeconds  = 15
    case oneMinute       = 60
    case threeMinutes    = 180
    case fiveMinutes     = 300
    case fifteenMinutes  = 900
    case thirtyMinutes   = 1800
    case oneHour         = 3600
    case never           = 0

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .fifteenSeconds:  return "15 seconds"
        case .oneMinute:       return "1 minute"
        case .threeMinutes:    return "3 minutes"
        case .fiveMinutes:     return "5 minutes"
        case .fifteenMinutes:  return "15 minutes"
        case .thirtyMinutes:   return "30 minutes"
        case .oneHour:         return "1 hour"
        case .never:           return "Never"
        }
    }

    /// UserDefaults key for the auto-hide enabled toggle (Bool).
    static let enabledUserDefaultsKey = "luma_auto_hide_enabled"

    /// UserDefaults key for the selected interval raw seconds value (Double).
    /// A stored value of 0 means "Never".
    static let intervalUserDefaultsKey = "luma_auto_hide_interval_seconds"

    /// Posted by CustomizationTabView when the user changes the auto-hide toggle or interval.
    /// CompanionManager observes this to update the idle timer immediately, bypassing the
    /// unreliable UserDefaults.didChangeNotification path.
    static let settingsChangedNotification = Notification.Name("lumaAutoHideSettingsChanged")

    /// Registers sensible defaults so first-launch behaviour is auto-hide after 5 minutes.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledUserDefaultsKey: true,
            intervalUserDefaultsKey: LumaAutoHideInterval.fiveMinutes.rawValue
        ])
    }

    /// Returns the `LumaAutoHideInterval` that best matches the stored seconds value.
    /// Falls back to `.fiveMinutes` if the stored value doesn't match any case.
    static func from(storedSeconds: Double) -> LumaAutoHideInterval {
        return LumaAutoHideInterval(rawValue: storedSeconds) ?? .fiveMinutes
    }
}
