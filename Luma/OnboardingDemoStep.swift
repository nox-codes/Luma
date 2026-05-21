//
//  OnboardingDemoStep.swift
//  Luma
//
//  Wizard step 5: the interactive demo. Shown only after all three permissions
//  are granted (enforced by OnboardingPermissionsStep upstream).
//
//  LumaDemoOrchestrator drives the scan → narrate → point → invite sequence.
//  The user can submit a real text command to complete the demo; the command
//  goes through the normal classifyAndRouteInput() pipeline.
//

import SwiftUI

@MainActor
struct OnboardingDemoStep: View {

    @ObservedObject var companionManager: CompanionManager
    var onDemoComplete: () -> Void

    @StateObject private var orchestrator = LumaDemoOrchestrator()
    @State private var userTextInput: String = ""
    @State private var hasSubmittedCommand: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Meet Luma")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(hex: "#ECEEED"))
                Text("Watch what Luma can see, then try a command.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#9BA39D"))
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 24)

            // Status area — shows what Luma is currently saying
            if !orchestrator.spokenText.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color(hex: "#2563EB"))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    Text(orchestrator.spokenText)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#ECEEED"))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }

            Spacer()

            // User input row — only shown once the orchestrator reaches the .inviting phase
            if case .inviting = orchestrator.phase {
                VStack(spacing: 10) {
                    Text("Try giving me a command")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#555D58"))

                    HStack(spacing: 10) {
                        TextField("Type a command…", text: $userTextInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#ECEEED"))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(hex: "#1A1C1A"))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                                    )
                            )
                            .onSubmit { submitDemoCommand() }

                        Button(action: submitDemoCommand) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color(hex: "#141614"))
                                .frame(width: 30, height: 30)
                                .background(Color.white)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(userTextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasSubmittedCommand)
                        .onHover { isHovering in
                            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }

                    Text("Or hold ⌃⌥ and speak")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#555D58"))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
            }

            // Completion state — shown after the user's command executes
            if case .complete = orchestrator.phase {
                VStack(spacing: 12) {
                    Text("You're all set!")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#34D399"))

                    Button(action: onDemoComplete) {
                        Text("Finish setup →")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(hex: "#ECEEED"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(hex: "#2563EB"))
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            orchestrator.start(companionManager: companionManager)
        }
        .onDisappear {
            // Cancel the demo sequence if the user navigates back or closes the wizard
            orchestrator.cancel()
        }
    }

    private func submitDemoCommand() {
        let command = userTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !hasSubmittedCommand else { return }
        hasSubmittedCommand = true
        orchestrator.markExecuting()
        // Route through the full intent classifier pipeline — the user's real first command
        Task { @MainActor in
            await companionManager.classifyAndRouteInput(command)
            orchestrator.markComplete()
        }
    }
}
