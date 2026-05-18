//
//  LumaOnboardingWindowManager.swift
//  Luma
//
//  Dedicated manager for the onboarding wizard window. Mirrors the pattern used by
//  LumaSettingsWindowManager: a borderless KeyAccepting NSWindow hosting a SwiftUI view.
//  The onboarding window is a separate, centred macOS window — not a sheet on the
//  companion panel — so it feels like a first-class app window.
//

import AppKit
import SwiftUI

// MARK: - LumaOnboardingWindowManager

@MainActor
final class LumaOnboardingWindowManager {

    static let shared = LumaOnboardingWindowManager()

    private var onboardingWindow: NSWindow?
    private let windowSize = NSSize(width: 760, height: 540)
    private let minimumWindowSize = NSSize(width: 680, height: 480)

    private init() {}

    /// Shows the onboarding wizard window. No-ops if already visible.
    /// Reads / writes `CompanionManager.shared.hasCompletedOnboarding` directly
    /// so the companion panel reacts when the wizard completes.
    func showOnboardingWindow() {
        if let existing = onboardingWindow, existing.isVisible { return }

        if onboardingWindow == nil {
            onboardingWindow = makeOnboardingWindow()
        }

        guard let onboardingWindow else { return }

        // Switch to regular activation so the window appears in the Dock and Cmd+Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow.center()
        onboardingWindow.orderFrontRegardless()
        onboardingWindow.makeKeyAndOrderFront(nil)
        onboardingWindow.makeMain()

        // Return to accessory mode (menu-bar-only, no Dock icon) when the window closes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: onboardingWindow,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Programmatically closes the onboarding window.
    /// Called from OnboardingWizardView.completeOnboarding() once the final step is done.
    func hideOnboardingWindow() {
        onboardingWindow?.orderOut(nil)
        // Release the window reference so it's rebuilt fresh if onboarding is triggered again
        // (e.g. after the user resets the app).
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Window Construction

    private func makeOnboardingWindow() -> NSWindow {
        // Binding bridges the SwiftUI wizard's completion back to CompanionManager's published state.
        // CompanionManager has no singleton — read/write UserDefaults directly,
        // which is the exact storage backing hasCompletedOnboarding uses.
        let completionBinding = Binding<Bool>(
            get: { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") },
            set: { UserDefaults.standard.set($0, forKey: "hasCompletedOnboarding") }
        )

        let window = KeyAcceptingOnboardingWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            // Borderless + resizable: custom rounded shape with no OS titlebar chrome.
            // KeyAcceptingOnboardingWindow overrides canBecomeKey/canBecomeMain so all
            // interactive elements (text fields, buttons, pickers) work normally.
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Luma — Setup"
        window.minSize = minimumWindowSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Draggable anywhere that isn't a button — same as the settings window.
        window.isMovableByWindowBackground = true

        let hostingView = NSHostingView(
            rootView: OnboardingWizardView(hasCompletedOnboarding: completionBinding)
                .preferredColorScheme(.dark)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.60), radius: 36, y: 14)
        )
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]

        // AppKit layer clip — removes the 1px OS border that appears on NSHostingView.
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 20
        hostingView.layer?.cornerCurve = CALayerCornerCurve.continuous
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = CGColor.clear

        window.contentView = hostingView
        return window
    }
}

// MARK: - KeyAcceptingOnboardingWindow

/// NSWindow subclass that accepts key / main status with a .borderless styleMask.
/// A plain borderless NSWindow returns false for canBecomeKey/canBecomeMain, which
/// prevents button clicks and text-field focus from working. Overriding both fixes that.
private final class KeyAcceptingOnboardingWindow: NSWindow {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}
