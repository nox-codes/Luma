//
//  LumaPermissionDragPopup.swift
//  Luma
//
//  A compact floating pill panel that lets the user drag Luma's .app bundle
//  into a System Settings privacy list to grant a permission.
//
//  Flow:
//  1. Caller calls showPopup(for:) — opens System Settings to the correct pane
//     and spawns this popup floating above it.
//  2. User drags the Luma icon from the popup into the System Settings list.
//     macOS accepts the .app bundle URL natively (same as dragging from Finder).
//  3. CompanionManager.refreshAllPermissions() polls every 1.5s and detects
//     the permission flip. It posts Notification.Name.lumaPermissionGranted
//     which this popup observes to auto-dismiss itself.
//

import AppKit
import Combine
import SwiftUI

/// The three permissions Luma requires.
enum LumaRequiredPermission: String, CaseIterable {
    case screenRecording
    case accessibility
    case microphone

    var displayName: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility:   return "Accessibility"
        case .microphone:      return "Microphone"
        }
    }

    /// Deep-link URL for the correct System Settings privacy pane.
    var systemSettingsURL: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
    }
}

extension Notification.Name {
    /// Posted by CompanionManager when a specific permission transitions to granted.
    /// userInfo key "permission" carries a LumaRequiredPermission rawValue String.
    static let lumaPermissionGranted = Notification.Name("lumaPermissionGranted")
}

/// Manages the lifecycle of one popup per permission type.
/// Ensures only one popup exists per permission even if the user taps "Give" multiple times.
/// ObservableObject conformance lets OnboardingPermissionsStep hold this as @StateObject,
/// preserving the single instance across SwiftUI body re-evaluations.
@MainActor
final class LumaPermissionDragPopupManager: ObservableObject {

    /// Active popups keyed by permission rawValue so the dictionary works correctly.
    private var activePopups: [String: LumaPermissionDragPopup] = [:]

    func showPopup(for permission: LumaRequiredPermission) {
        // Open System Settings to the correct privacy pane
        NSWorkspace.shared.open(permission.systemSettingsURL)

        // Show the drag popup (or do nothing if already visible for this permission)
        let key = permission.rawValue
        if activePopups[key] == nil {
            let popup = LumaPermissionDragPopup(permission: permission) { [weak self] in
                self?.activePopups.removeValue(forKey: key)
            }
            activePopups[key] = popup
            popup.show()
        }
    }
}

// MARK: - LumaPermissionDragPopup

/// One floating pill panel for one permission type.
@MainActor
final class LumaPermissionDragPopup: NSObject {

    private let permission: LumaRequiredPermission
    private let onDismiss: @MainActor () -> Void
    private var panel: NSPanel?
    private var grantObserver: NSObjectProtocol?

    init(permission: LumaRequiredPermission, onDismiss: @escaping @MainActor () -> Void) {
        self.permission = permission
        self.onDismiss = onDismiss
    }

    func show() {
        let contentView = PermissionDragPillView(permission: permission)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 72)

        let dragPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dragPanel.isFloatingPanel = true
        dragPanel.level = .floating
        dragPanel.isOpaque = false
        dragPanel.backgroundColor = .clear
        dragPanel.hasShadow = true
        dragPanel.hidesOnDeactivate = false
        dragPanel.isExcludedFromWindowsMenu = true
        dragPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dragPanel.contentView = hostingView

        // Position at the bottom center of the primary screen, just above the dock
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelX = screenFrame.midX - 200   // centered (half of 400)
            let panelY = screenFrame.minY + 24    // 24pt above dock/bottom
            dragPanel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        dragPanel.makeKeyAndOrderFront(nil)
        dragPanel.orderFrontRegardless()
        self.panel = dragPanel

        // Auto-dismiss when the matching permission is granted.
        // The userInfo "permission" key carries the rawValue String so we can
        // compare without needing to store the enum (which isn't Equatable by default).
        grantObserver = NotificationCenter.default.addObserver(
            forName: .lumaPermissionGranted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawValue = notification.userInfo?["permission"] as? String,
                  rawValue == self.permission.rawValue else { return }
            // The closure runs on queue: .main but is not @MainActor-isolated in Swift's
            // type system. Use Task { @MainActor } to call the @MainActor-isolated dismiss().
            Task { @MainActor [weak self] in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        if let observer = grantObserver {
            NotificationCenter.default.removeObserver(observer)
            grantObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        onDismiss()
    }
}

// MARK: - Pill View (SwiftUI)

/// The pill-shaped drag source view shown inside the popup panel.
private struct PermissionDragPillView: View {

    let permission: LumaRequiredPermission

    @State private var glowPulse: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            // Drag source: Luma .app icon
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 44, height: 44)
                .onDrag {
                    let appURL = URL(fileURLWithPath: Bundle.main.bundlePath)
                    return NSItemProvider(object: appURL as NSURL)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Drag Luma to grant permission")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                let subtitleText = permission.displayName + " · Drag into the list in System Settings"
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#9BA39D"))
                    .lineLimit(1)
            }

            Spacer()

            // Arrow hint
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(Color.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(Color(hex: "#1A1C1A"))
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(glowPulse ? 0.5 : 0.15), lineWidth: 1.5)
                )
        )
        .preferredColorScheme(.dark)
        .onAppear {
            // Pulse the border to draw attention
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}
