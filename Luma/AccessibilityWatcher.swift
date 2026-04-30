//
//  AccessibilityWatcher.swift
//  leanring-buddy
//
//  Monitors the macOS Accessibility API for UI state changes and publishes
//  structured events so StepValidator can check them against the current
//  walkthrough step. Uses a polling Timer to track frontmost app changes,
//  and AXObserver for fine-grained element events within the active app.
//

import ApplicationServices
import AppKit
import Foundation
import Combine

// MARK: - AccessibilityEvent

/// A structured event published by AccessibilityWatcher when something meaningful
/// happens in the user's UI — a focus change, a value change, a window appearing, etc.
struct AccessibilityEvent {
    enum EventType: String {
        case focusChanged   // AXFocusedUIElementChanged — user clicked or tabbed to a new element
        case textSelected   // AXSelectedTextChanged — user highlighted or changed selected text
        case valueChanged   // AXValueChanged — a field's value changed (e.g. typed into a box)
        case windowCreated  // AXWindowCreated — a new window opened in the app
        case appActivated   // kAXApplicationActivatedNotification — user switched to a different app
    }

    let type: EventType
    let elementRole: String?    // AXRole of the element (e.g. "AXButton", "AXTextField")
    let elementTitle: String?   // AXTitle or AXDescription of the element
    let elementValue: String?   // AXValue (e.g. current text in a field)
    let appBundleID: String     // Bundle ID of the frontmost app at time of event
    let timestamp: Date
}

// MARK: - AccessibilityWatcher

/// Monitors the macOS Accessibility API and publishes AccessibilityEvents.
/// The WalkthroughEngine listens via the `onEvent` callback to check whether
/// the user completed the current step.
@MainActor
final class AccessibilityWatcher: ObservableObject {
    static let shared = AccessibilityWatcher()

    @Published private(set) var latestEvent: AccessibilityEvent?
    @Published private(set) var isAccessibilityPermissionGranted: Bool = false

    /// Called whenever a new accessibility event fires. Used by WalkthroughEngine
    /// to forward events to StepValidator without needing Combine subscriptions.
    var onEvent: ((AccessibilityEvent) -> Void)?

    // The currently observed application PID. We track this so we can
    // tear down and rebuild the AXObserver when the frontmost app changes.
    private var currentlyObservedPID: pid_t = 0
    private var axObserver: AXObserver?

    // Timer that polls for frontmost app changes every 0.5 seconds.
    // We use polling here because there's no cheap system notification for
    // "the frontmost app just changed" that works reliably across all macOS versions
    // without requiring an accessibility observer on the system process itself.
    private var frontmostAppPollingTimer: Timer?

    // Named constant for the polling interval — 0.5s is fast enough to feel
    // responsive while light enough to avoid burning CPU during a walkthrough.
    private let frontmostAppPollingIntervalSeconds: TimeInterval = 0.5

    private init() {
        isAccessibilityPermissionGranted = AXIsProcessTrusted()
    }

    // MARK: - Permission Handling

    /// Checks whether the Accessibility permission is granted.
    /// If not granted, shows the system prompt asking the user to enable it,
    /// then opens the relevant System Settings pane so they can do so.
    func checkAndRequestPermission() {
        // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt: true will
        // cause macOS to show the standard "Enable access for assistive devices" dialog.
        // Bridge kAXTrustedCheckOptionPrompt (CFString) to a String key first.
        // Passing the CFString directly as a dictionary key causes a type error in Swift.
        let axPromptOptionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let optionsDictionary = [axPromptOptionKey: true] as CFDictionary
        let isNowTrusted = AXIsProcessTrustedWithOptions(optionsDictionary)
        isAccessibilityPermissionGranted = isNowTrusted

        if !isNowTrusted {
            // Open the Accessibility pane of Privacy & Security in System Settings so
            // the user can toggle the permission without hunting through menus.
            let accessibilitySettingsURL = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )!
            NSWorkspace.shared.open(accessibilitySettingsURL)
        }
    }

    // MARK: - Watching

    /// Starts monitoring the frontmost application for UI events.
    /// Safe to call multiple times — re-entrancy is handled by checking the timer.
    func startWatching() {
        guard frontmostAppPollingTimer == nil else {
            // Already watching — no need to install a second timer
            return
        }

        // Re-check permission state in case it was granted since last check
        isAccessibilityPermissionGranted = AXIsProcessTrusted()

        // Start the polling timer on the main run loop so the callbacks fire
        // on the main actor, where all our state updates live.
        frontmostAppPollingTimer = Timer.scheduledTimer(
            withTimeInterval: frontmostAppPollingIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollFrontmostApplicationForChanges()
            }
        }

        // Immediately observe the current frontmost app so we don't miss events
        // that happen before the first timer tick
        if let currentFrontmostApp = NSWorkspace.shared.frontmostApplication {
            installAXObserver(forApp: currentFrontmostApp)
        }
    }

    /// Stops monitoring and cleans up the AXObserver and polling timer.
    func stopWatching() {
        frontmostAppPollingTimer?.invalidate()
        frontmostAppPollingTimer = nil
        removeCurrentAXObserver()
        currentlyObservedPID = 0
    }

    // MARK: - Frontmost App Polling

    /// Called on each timer tick. Checks whether the frontmost app has changed,
    /// and if so, fires an appActivated event and re-installs the AXObserver.
    private func pollFrontmostApplicationForChanges() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return }
        let frontmostAppPID = frontmostApp.processIdentifier

        // Only act when the frontmost app actually changed
        guard frontmostAppPID != currentlyObservedPID else { return }

        let bundleID = frontmostApp.bundleIdentifier ?? "unknown"

        let appActivatedEvent = AccessibilityEvent(
            type: .appActivated,
            elementRole: nil,
            elementTitle: frontmostApp.localizedName,
            elementValue: nil,
            appBundleID: bundleID,
            timestamp: Date()
        )

        publishEvent(appActivatedEvent)

        // Re-install the AXObserver for the new frontmost app
        installAXObserver(forApp: frontmostApp)
    }

    // MARK: - AXObserver Management

    /// Installs an AXObserver on the given application to receive element-level events.
    /// Tears down any existing observer first to avoid double-firing.
    private func installAXObserver(forApp app: NSRunningApplication) {
        removeCurrentAXObserver()

        let pid = app.processIdentifier

        // AXObserverCreate takes a C callback — we pass `self` as the refcon so
        // the callback can call back into the AccessibilityWatcher instance.
        var newObserver: AXObserver?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        // AXObserverCreate requires a C function pointer — use a non-capturing literal
        // closure instead of a named function reference to satisfy the Swift compiler.
        let createResult = AXObserverCreate(pid, { _, element, notification, userData in
            guard let userData = userData else { return }
            let watcher = Unmanaged<AccessibilityWatcher>.fromOpaque(userData).takeUnretainedValue()
            var elementOwnerPID: pid_t = 0
            AXUIElementGetPid(element, &elementOwnerPID)
            let bundleID = NSRunningApplication(processIdentifier: elementOwnerPID)?.bundleIdentifier ?? "unknown"
            let notificationString = notification as String
            Task { @MainActor in
                watcher.handleAXNotification(notification: notificationString, element: element, appBundleID: bundleID)
            }
        }, &newObserver)
        guard createResult == .success, let createdObserver = newObserver else {
            LumaLogger.log("[AccessibilityWatcher] AXObserverCreate failed for PID \(pid) — \(createResult.rawValue)")
            return
        }

        // REQUIRED: set only after success
        currentlyObservedPID = pid

        let appElement = AXUIElementCreateApplication(pid)

        let notificationsToObserve: [(String, AccessibilityEvent.EventType)] = [
            (kAXFocusedUIElementChangedNotification, .focusChanged),
            (kAXValueChangedNotification, .valueChanged),
            (kAXWindowCreatedNotification, .windowCreated),
            (kAXSelectedTextChangedNotification, .textSelected)
        ]

        for (notificationName, _) in notificationsToObserve {
            AXObserverAddNotification(
                createdObserver,
                appElement,
                notificationName as CFString,
                selfPointer
            )
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .defaultMode
        )

        axObserver = createdObserver
    }
    
    /// Removes the current AXObserver from the run loop and releases it.
    private func removeCurrentAXObserver() {
        guard let existingObserver = axObserver else { return }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(existingObserver),
            .defaultMode
        )
        axObserver = nil
    }

    // MARK: - Event Handling

    /// Called by the C-level AXObserver callback when an AX notification fires.
    /// Reads the element attributes and constructs an AccessibilityEvent.
    fileprivate func handleAXNotification(
        notification: String,
        element: AXUIElement,
        appBundleID: String
    ) {
        let elementRole = extractAttributeString(from: element, attribute: kAXRoleAttribute)
        let elementTitle = extractAttributeString(from: element, attribute: kAXTitleAttribute)
            ?? extractAttributeString(from: element, attribute: kAXDescriptionAttribute)
        let elementValue = extractAttributeString(from: element, attribute: kAXValueAttribute)

        // Map the AX notification string to our typed EventType enum
        let eventType: AccessibilityEvent.EventType
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            eventType = .focusChanged
        case kAXValueChangedNotification:
            eventType = .valueChanged
        case kAXWindowCreatedNotification:
            eventType = .windowCreated
        case kAXSelectedTextChangedNotification:
            eventType = .textSelected
        default:
            eventType = .focusChanged
        }

        let accessibilityEvent = AccessibilityEvent(
            type: eventType,
            elementRole: elementRole,
            elementTitle: elementTitle,
            elementValue: elementValue,
            appBundleID: appBundleID,
            timestamp: Date()
        )

        publishEvent(accessibilityEvent)
    }

    /// Publishes an event to both `latestEvent` and the `onEvent` callback.
    private func publishEvent(_ event: AccessibilityEvent) {
        latestEvent = event
        onEvent?(event)
    }

    // MARK: - AX Attribute Helpers

    /// Reads a string attribute from an AXUIElement.
    /// Returns nil if the attribute doesn't exist or isn't a String.
    ///
    /// We use this helper throughout instead of inline AXUIElementCopyAttributeValue
    /// calls because the CoreFoundation bridging (CFTypeRef → String) is error-prone
    /// and centralising it prevents duplicate casting mistakes.
    private func extractAttributeString(from element: AXUIElement, attribute: String) -> String? {
        var rawAttributeValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawAttributeValue)
        guard result == .success, let attributeValue = rawAttributeValue else { return nil }

        // CFTypeRef can be a CFString, CFNumber, AXUIElement, etc.
        // We only handle CFString here — other types aren't useful as strings for matching.
        if CFGetTypeID(attributeValue) == CFStringGetTypeID() {
            return (attributeValue as! CFString) as String
        }
        return nil
    }
}

// MARK: - C-Level AXObserver Callback

/// Plain C callback required by the AXObserver API. AXObserver cannot take a Swift closure
/// directly — it requires a function pointer. We use the refcon (userdata pointer) to retrieve
/// the AccessibilityWatcher instance and forward the event into Swift.
private func axEventCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }

    // Retrieve the AccessibilityWatcher instance from the opaque pointer we stored in userData
    let accessibilityWatcher = Unmanaged<AccessibilityWatcher>.fromOpaque(userData).takeUnretainedValue()

    // Look up the bundle ID of the app that owns this element.
    // We get the PID from the element, then find the running app with that PID.
    var elementOwnerPID: pid_t = 0
    AXUIElementGetPid(element, &elementOwnerPID)
    let bundleID = NSRunningApplication(processIdentifier: elementOwnerPID)?.bundleIdentifier ?? "unknown"

    let notificationString = notification as String

    // Forward to the actor-isolated method. We dispatch to the main actor because
    // AXObserver callbacks can fire on any thread and all our state is @MainActor.
    Task { @MainActor in
        accessibilityWatcher.handleAXNotification(
            notification: notificationString,
            element: element,
            appBundleID: bundleID
        )
    }
}
