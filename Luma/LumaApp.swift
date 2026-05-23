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
    /// Held strongly because SPUStandardUpdaterController stores the delegate weakly.
    private var sparkleActivationDelegate: SparkleActivationDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force dark appearance app-wide so system controls (Picker, TextField, etc.)
        // always render with dark chrome, even when macOS is in light mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        LumaLogger.log("🎯 Luma: Starting...")
        LumaLogger.log("🎯 Luma: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        LumaAutoHideInterval.registerDefaults()

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
        startSparkleUpdater()
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
        let activationDelegate = SparkleActivationDelegate()
        self.sparkleActivationDelegate = activationDelegate

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: activationDelegate
        )
        self.sparkleUpdaterController = updaterController

        // Listen for requests from the companion panel to trigger a manual Sparkle update check.
        // The panel posts .lumaCheckForUpdates when the user taps the update icon in the bottom bar.
        NotificationCenter.default.addObserver(
            forName: .lumaCheckForUpdates,
            object: nil,
            queue: .main
        ) { [weak updaterController] _ in
            guard let updater = updaterController?.updater else {
                LumaLogger.log("[Sparkle] updater is nil — cannot check")
                return
            }
            LumaLogger.log("[Sparkle] checkForUpdates triggered — canCheck: \(updater.canCheckForUpdates)")

            // Hide Luma's floating panel immediately so it doesn't sit on top
            // of Sparkle's update window (floating level > normal level).
            NSApp.windows
                .filter { $0 is NSPanel && $0.level == .floating }
                .forEach { $0.orderOut(nil) }

            // Use updater.checkForUpdates() directly — the controller wrapper
            // silently skips the call when canCheckForUpdates is false (e.g. if
            // a background check is still pending). The direct call bypasses that.
            updater.checkForUpdates()

            // After a short delay, force any new Sparkle windows to the front
            // in case activation policy hasn't propagated yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.windows
                    .filter { $0.isVisible && !($0 is NSPanel) }
                    .forEach { $0.makeKeyAndOrderFront(nil) }
            }
        }

        do {
            try updaterController.updater.start()
        } catch {
            LumaLogger.log("⚠️ Luma: Sparkle updater failed to start: \(error)")
        }
    }

}

/// Manages activation policy around Sparkle's update UI.
///
/// Luma runs as an LSUIElement (.accessory) app — it has no dock icon and never
/// becomes the frontmost application on its own. Sparkle creates real NSWindows
/// for its progress/update sheets, but those windows stay hidden behind other apps
/// because the app is never "active". This delegate switches to .regular while
/// Sparkle UI is on screen so its windows receive focus, then switches back to
/// .accessory when the session ends.
private final class SparkleActivationDelegate: NSObject, SPUStandardUserDriverDelegate {

    /// Called before Sparkle is about to show a new update alert to the user.
    /// Activate the app so the alert window can come to the front.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        LumaLogger.log("[Sparkle] willHandleShowingUpdate — activating app")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillShowModalAlert() {
        LumaLogger.log("[Sparkle] willShowModalAlert — activating app")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        LumaLogger.log("[Sparkle] willFinishUpdateSession — returning to accessory")
        NSApp.setActivationPolicy(.accessory)
    }
}

extension Notification.Name {
    /// Posted by the companion panel when the user taps "Check for Updates".
    /// Observed by CompanionAppDelegate to invoke Sparkle's native update flow.
    static let lumaCheckForUpdates = Notification.Name("lumaCheckForUpdates")
}
