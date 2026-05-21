//
//  OnboardingPermissionsStep.swift
//  Luma
//
//  Wizard step 4: shows all three required permissions with live status chips.
//  The "Continue" button is only enabled when all three are granted.
//
//  Each "Give" button:
//  1. Opens System Settings to the correct privacy pane via deep link.
//  2. Spawns a LumaPermissionDragPopup so the user can drag Luma into the list.
//
//  Permission status is read from CompanionManager's @Published properties,
//  which are updated every 1.5s by the existing permission-polling timer.
//

import SwiftUI

@MainActor
struct OnboardingPermissionsStep: View {

    /// Injected from OnboardingWizardView so this step can read live permission state.
    @ObservedObject var companionManager: CompanionManager

    /// Called when all permissions are granted and the user taps Continue.
    var onAllPermissionsGranted: () -> Void

    private let dragPopupManager = LumaPermissionDragPopupManager()

    var allGranted: Bool {
        companionManager.hasScreenRecordingPermission
        && companionManager.hasAccessibilityPermission
        && companionManager.hasMicrophonePermission
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Give Luma access")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(hex: "#ECEEED"))
                Text("All three permissions are required to continue.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#9BA39D"))
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 28)

            // Permission rows
            VStack(spacing: 10) {
                permissionRow(
                    icon: "display",
                    name: "Screen Recording",
                    description: "Lets Luma see your screen to assist you",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    permission: .screenRecording
                )
                permissionRow(
                    icon: "accessibility",
                    name: "Accessibility",
                    description: "Lets Luma read and interact with UI elements",
                    isGranted: companionManager.hasAccessibilityPermission,
                    permission: .accessibility
                )
                permissionRow(
                    icon: "mic",
                    name: "Microphone",
                    description: "Lets Luma hear your voice commands",
                    isGranted: companionManager.hasMicrophonePermission,
                    permission: .microphone
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            // Continue button — only enabled when all permissions are granted
            VStack(spacing: 8) {
                Button(action: { if allGranted { onAllPermissionsGranted() } }) {
                    Text("Continue →")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(allGranted ? Color(hex: "#ECEEED") : Color(hex: "#444"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(allGranted ? Color(hex: "#2563EB") : Color(hex: "#1A1C1A"))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!allGranted)
                .onHover { isHovering in
                    if allGranted {
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }

                if !allGranted {
                    Text("Waiting for \(missingPermissionNames)…")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#555D58"))
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    private var missingPermissionNames: String {
        var missing: [String] = []
        if !companionManager.hasScreenRecordingPermission { missing.append("Screen Recording") }
        if !companionManager.hasAccessibilityPermission  { missing.append("Accessibility") }
        if !companionManager.hasMicrophonePermission     { missing.append("Microphone") }
        return missing.joined(separator: ", ")
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        name: String,
        description: String,
        isGranted: Bool,
        permission: LumaRequiredPermission
    ) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(isGranted ? Color(hex: "#34D399") : Color(hex: "#9BA39D"))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isGranted ? Color(hex: "#1A2F1A") : Color(hex: "#1A1C1A"))
                )

            // Name + description
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#ECEEED"))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#555D58"))
            }

            Spacer()

            // Status chip or Give button
            if isGranted {
                Label("Granted", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#34D399"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(hex: "#1A2F1A"))
                            .overlay(Capsule().stroke(Color(hex: "#2A5A2A"), lineWidth: 1))
                    )
            } else {
                Button("Give") {
                    dragPopupManager.showPopup(for: permission)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#ECEEED"))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: "#2563EB"))
                )
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "#1A1C1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isGranted ? Color(hex: "#2A5A2A") : Color(hex: "#2E322E"),
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isGranted)
    }
}
