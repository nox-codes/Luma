//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI


struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var accountManager = AccountManager.shared
    /// Observed directly so the view re-renders when tutorial step/active state changes.
    @ObservedObject private var tutorialManager: PostOnboardingTutorialManager
    /// Observed so the panel re-renders on every walkthrough state transition.
    @ObservedObject private var walkthroughEngine = WalkthroughEngine.shared

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._tutorialManager = ObservedObject(wrappedValue: companionManager.tutorialManager)
    }
    @State private var emailInput: String = ""
    @State private var textInputFallbackDraft: String = ""
    @State private var showPINEntryForSettings = false
    @State private var showQuitConfirmation = false
    @State private var tutorialPulseScale: CGFloat = 1.0
    @State private var tutorialPulseOpacity: Double = 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, DS.Spacing.lg)

            permissionsCopySection
                .padding(.top, DS.Spacing.lg)
                .padding(.horizontal, DS.Spacing.lg)

            if let apiError = companionManager.lastAPIErrorMessage {
                Spacer()
                    .frame(height: 10)

                apiErrorBanner(message: apiError)
                    .padding(.horizontal, DS.Spacing.lg)
            }

            // When a walkthrough is active, replace the normal content area with the
            // step progress card so it's the user's primary focus.
            if walkthroughEngine.isRunning {
                Spacer()
                    .frame(height: 12)

                walkthroughProgressCard
                    .padding(.horizontal, DS.Spacing.lg)

            } else if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, DS.Spacing.lg)

                if companionManager.showTextInputFallback {
                    Spacer()
                        .frame(height: 12)

                    textInputFallbackRow
                        .padding(.horizontal, DS.Spacing.lg)
                }

                // Agent mode section — shown when agent mode is enabled
                if companionManager.isAgentModeEnabled {
                    Spacer()
                        .frame(height: 12)

                    AgentModePanelSection(
                        session: companionManager.activeAgentSession,
                        responseCard: companionManager.activeAgentSession.latestResponseCard,
                        submitAgentPrompt: { prompt in
                            companionManager.submitAgentPromptFromUI(prompt)
                        },
                        dismissResponseCard: {
                            companionManager.activeAgentSession.dismissLatestResponseCard()
                        },
                        runSuggestedNextAction: { action in
                            companionManager.submitAgentPromptFromUI(action)
                        },
                        showSettings: {
                            LumaSettingsWindowManager.shared.showSettingsWindow()
                        },
                        isRecordingVoice: companionManager.agentVoiceRecordingSessionID == companionManager.activeAgentSessionID,
                        onVoiceToggle: {
                            if let activeID = companionManager.activeAgentSessionID {
                                companionManager.toggleAgentVoiceRecording(sessionID: activeID)
                            }
                        }
                    )
                    .padding(.horizontal, DS.Spacing.lg)
                }
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, DS.Spacing.lg)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, DS.Spacing.lg)
            }

            // Show Luma toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showLumaCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, DS.Spacing.lg)

            bottomBar
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
        }
        .frame(width: 356)
        .background(panelBackground)
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.2), value: companionManager.allPermissionsGranted)
        .animation(.easeInOut(duration: 0.2), value: walkthroughEngine.isRunning)
        .animation(.easeInOut(duration: 0.2), value: companionManager.showTextInputFallback)
        .overlay(alignment: .top) {
            if tutorialManager.isActive {
                tutorialOverlayCard
            }
        }
        .onAppear {
            // Start the post-onboarding tutorial the first time the panel opens
            // after onboarding completes. startIfNeeded() is a no-op if already done.
            if companionManager.hasCompletedOnboarding {
                tutorialManager.startIfNeeded()
            }
        }
        .sheet(isPresented: $showPINEntryForSettings) {
            PINEntryView(mode: .verify, title: "Enter PIN to open Settings") {
                showPINEntryForSettings = false
                LumaSettingsWindowManager.shared.showSettingsWindow()
            } onCancel: {
                showPINEntryForSettings = false
            }
        }
        .alert("Quit Luma?", isPresented: $showQuitConfirmation) {
            Button("Quit", role: .destructive) { NSApp.terminate(nil) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(
            // Force onboarding if the flag isn't set, or if the user somehow lost
            // their account or API profiles (e.g. cleared app data manually).
            get: {
                !companionManager.hasCompletedOnboarding
                    || ProfileManager.shared.profiles.isEmpty
                    || AccountManager.shared.currentAccount == nil
            },
            set: { if !$0 { companionManager.hasCompletedOnboarding = true } }
        )) {
            OnboardingWizardView(hasCompletedOnboarding: Binding(
                get: { companionManager.hasCompletedOnboarding },
                set: { companionManager.hasCompletedOnboarding = $0 }
            ))
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Luma")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(DS.Colors.textPrimary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .glowOnHover()
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if companionManager.showTextInputFallback {
                Text("Voice unavailable — type below instead.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Hold Control+Option to talk.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Luma.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Luma.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Omoju Oluwamayowa. This is Luma.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Luma will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - API Error Banner

    /// Shown below the status copy when the last AI request failed.
    /// Displays the raw error from the API (e.g. "OpenRouter API Error (401): ...")
    /// so the user can diagnose issues without needing Xcode open.
    /// Tapping the X dismisses it by clearing `lastAPIErrorMessage` on the manager.
    private func apiErrorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.4))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                companionManager.dismissLastAPIError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.25, green: 0.1, blue: 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(red: 1.0, green: 0.6, blue: 0.4).opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Text Input Fallback

    /// Shown in place of the "Hold Control+Option" hint when voice input is
    /// unavailable (mic or speech recognition permission denied). Lets the user
    /// type a message and submit it through the same AI pipeline as a voice transcript.
    private var textInputFallbackRow: some View {
        HStack(spacing: 8) {
            TextField("Type a message…", text: $textInputFallbackDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .onSubmit {
                    submitTextInputFallback()
                }

            Button(action: submitTextInputFallback) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(textInputFallbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? DS.Colors.textTertiary
                        : DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(textInputFallbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    private func submitTextInputFallback() {
        let trimmedText = textInputFallbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        textInputFallbackDraft = ""
        companionManager.submitTextInput(trimmedText)
    }

    // MARK: - Post-Onboarding Tutorial Overlay

    /// Full-panel card that covers the normal content while the tutorial is active.
    /// Floats over the panel via `.overlay(alignment: .top)` so it fills the same
    /// visual space without disturbing the underlying layout.
    private var tutorialOverlayCard: some View {
        let tutorial = tutorialManager
        let step = tutorial.currentStep

        return VStack(alignment: .leading, spacing: 0) {
            // Mirror the panel header so the card sits flush below it
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, DS.Spacing.lg)

            VStack(alignment: .leading, spacing: 16) {
                // Step text
                Text(step?.text ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.none, value: tutorial.currentStepIndex)

                // Pulse ring — only shown for shortcutHint steps since the
                // menu bar icon and cursor bubble are outside the panel
                if step?.highlightTarget == .shortcutHint {
                    shortcutHintPulseRing
                }

                // Progress dots
                HStack(spacing: 6) {
                    ForEach(0..<tutorial.steps.count, id: \.self) { dotIndex in
                        Circle()
                            .fill(dotIndex <= tutorial.currentStepIndex
                                  ? DS.Colors.accent
                                  : DS.Colors.borderSubtle)
                            .frame(width: 5, height: 5)
                    }
                    Spacer()

                    // Next / Done button
                    Button(tutorial.isLastStep ? "Done" : "Next →") {
                        tutorial.advance()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(DS.Colors.surface1)

            Spacer()
        }
        .background(DS.Colors.surface1)
        // Clip so the card doesn't overflow the rounded panel corners
        .clipShape(Rectangle())
        .id(tutorial.currentStepIndex)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: tutorial.isActive)
    }

    // MARK: - Walkthrough Progress Card

    /// Shown in the panel body whenever a walkthrough is active (planning, confirming, or executing).
    /// Replaces the normal model picker / shortcut hint row so the walkthrough is the user's focus.
    @ViewBuilder
    private var walkthroughProgressCard: some View {
        switch walkthroughEngine.state {

        case .planning:
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Planning steps…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }
            .padding(.vertical, 8)

        case .confirming(let steps):
            walkthroughConfirmationCard(steps: steps)

        case .executing(let steps, let currentIndex):
            walkthroughExecutingCard(steps: steps, currentIndex: currentIndex)

        case .complete:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DS.Colors.success)
                Text("Task complete!")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }
            .padding(.vertical, 8)

        default:
            EmptyView()
        }
    }

    /// Shows the AI-generated step list and a Begin button so the user can review before starting.
    private func walkthroughConfirmationCard(steps: [WalkthroughStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready to begin?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            // Step list preview
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(step.index + 1).")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 16, alignment: .trailing)
                        Text(step.instruction)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    walkthroughEngine.cancelWalkthrough()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Spacer()

                Button("Begin →") {
                    walkthroughEngine.confirmAndBeginWalkthrough()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Shows step progress, current instruction, element name, step list, and action buttons.
    private func walkthroughExecutingCard(steps: [WalkthroughStep], currentIndex: Int) -> some View {
        let currentStep = steps[currentIndex]

        return VStack(alignment: .leading, spacing: 10) {

            // Progress header row: "Step 2 of 5"  [Cancel]
            HStack {
                Text("Step \(currentIndex + 1) of \(steps.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)

                Spacer()

                Button("Cancel") {
                    walkthroughEngine.cancelWalkthrough()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            // Current instruction — large and prominent
            Text(currentStep.instruction)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // What element to look for
            if !currentStep.elementName.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Looking for: \(currentStep.elementName)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            // Step list — shows ✓ done, → current, ○ upcoming
            VStack(alignment: .leading, spacing: 3) {
                ForEach(steps) { step in
                    let isCompleted = step.index < currentIndex
                    let isCurrent   = step.index == currentIndex

                    HStack(spacing: 6) {
                        Group {
                            if isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(DS.Colors.success)
                            } else if isCurrent {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundColor(DS.Colors.accent)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                        }
                        .font(.system(size: 10))

                        Text(step.instruction)
                            .font(.system(size: 11))
                            .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            // Skip button — lets the user jump past a step they've already done or don't need
            Button("Skip this step →") {
                walkthroughEngine.skipCurrentStep()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.vertical, 4)
    }

    /// A subtle pulsing outline that draws attention to the Ctrl+Option shortcut
    /// hint — shown during tutorial steps that reference the voice shortcut.
    private var shortcutHintPulseRing: some View {
        Text("Hold Control+Option to talk")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.accent.opacity(tutorialPulseOpacity), lineWidth: 1.5)
                    .scaleEffect(tutorialPulseScale)
            )
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                ) {
                    tutorialPulseOpacity = 0.15
                    tutorialPulseScale = 1.04
                }
            }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.textPrimary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Luma Cursor Toggle

    private var showLumaCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Luma")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isLumaCursorEnabled },
                set: { companionManager.setLumaCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        // Shows the model set in Settings → API Profile. Tapping the row opens Settings.
        let activeModelID = ProfileManager.shared.activeProfile?.selectedModel ?? ""
        let displayModelName = activeModelID.isEmpty ? "No model set" : activeModelID

        return HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Button(action: openSettingsWithPINCheck) {
                Text(displayModelName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(activeModelID.isEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.textPrimary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Change model in Settings")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bottom Bar

    /// Bottom bar with user avatar on the left and action icons on the right.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Left: avatar circle showing user's initials from AccountManager
            if let account = accountManager.currentAccount {
                LumaAvatarView(initials: account.avatarInitials, size: 28)
            } else {
                // Placeholder avatar when no account exists yet (pre-onboarding)
                Circle()
                    .fill(DS.Colors.textPrimary.opacity(0.15))
                    .frame(width: 28, height: 28)
            }

            Spacer()

            // Right: gear icon (Settings, PIN-guarded) + power icon (Quit, with confirmation)
            HStack(spacing: 14) {
                Button(action: openSettingsWithPINCheck) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .glowOnHover()
                .help("Settings")

                Button(action: { showQuitConfirmation = true }) {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .glowOnHover(color: DS.Colors.destructive)
                .help("Quit Luma")
            }
        }
    }

    /// Opens Settings. If a PIN is set, requires the user to verify it first.
    private func openSettingsWithPINCheck() {
        if PINManager.shared.hasPIN {
            showPINEntryForSettings = true
        } else {
            LumaSettingsWindowManager.shared.showSettingsWindow()
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Colors.background)

            // Subtle noise texture overlay for visual depth (PRD 7.3)
            NoiseTextureView(opacity: 0.03)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
