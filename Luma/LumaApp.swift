//
//  LumaApp.swift
//  Luma
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ApplicationServices
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct LumaApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force dark appearance app-wide so system controls (Picker, TextField, etc.)
        // always render with dark chrome, even when macOS is in light mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        LumaLogger.log("🎯 Luma: Starting...")
        LumaLogger.log("🎯 Luma: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        // Only prompt for accessibility if onboarding is already done.
        // First-time users will be prompted for accessibility at the end of the
        // onboarding wizard so the two flows don't overlap and confuse the user.
        if !AXIsProcessTrusted() && companionManager.hasCompletedOnboarding {
            let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
            let options = [promptKey: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        LumaAnalytics.configure()
        LumaAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        LumaUpdateManager.shared.startChecking()
        // startSparkleUpdater()  — uncomment once GitHub Actions appcast workflow is set up
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                LumaLogger.log("🎯 Luma: Registered as login item")
            } catch {
                LumaLogger.log("⚠️ Luma: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            LumaLogger.log("⚠️ Luma: Sparkle updater failed to start: \(error)")
        }
    }
}
