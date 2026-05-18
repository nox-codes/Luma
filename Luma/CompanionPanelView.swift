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

    // Observing this key causes the panel to re-render when the accent theme changes,
    // so DS.Colors.accent / DS.Colors.accentText (which read LumaAccentTheme.current)
    // immediately reflect the new color across all panel UI.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.blue.rawValue

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

    // Status dot pulse animation state — driven by voiceState / walkthrough activity.
    @State private var statusDotPulseScale: CGFloat = 1.0
    @State private var statusDotPulseOpacity: Double = 1.0

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
                    .lumaFadeUp()

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

            bottomBar
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
            // Show the onboarding wizard window if the user hasn't completed setup,
            // or if their account/API profiles are missing (e.g. after a data reset).
            let needsOnboarding = !companionManager.hasCompletedOnboarding
                || ProfileManager.shared.profiles.isEmpty
                || AccountManager.shared.currentAccount == nil
            if needsOnboarding {
                LumaOnboardingWindowManager.shared.showOnboardingWindow()
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
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            // Status dot — 8pt circle with glow. Pulses when Luma is actively working.
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.5), radius: 5)
                .scaleEffect(statusDotPulseScale)
                .opacity(statusDotPulseOpacity)
                .onChange(of: statusDotShouldPulse) { shouldPulse in
                    if shouldPulse {
                        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                            statusDotPulseScale = 0.88
                            statusDotPulseOpacity = 0.55
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) {
                            statusDotPulseScale = 1.0
                            statusDotPulseOpacity = 1.0
                        }
                    }
                }

            Text("Luma")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            // Status displayed as a pill badge — surface3 background, tertiary text, 10pt font
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(DS.Colors.surface3))

            // Dismiss button — 24pt circle with surface3 fill
            Button(action: {
                NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(DS.Colors.surface3)
                    )
            }
            .buttonStyle(.plain)
            .glowOnHover()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    /// True when the status dot should animate with the pulse breathing effect.
    private var statusDotShouldPulse: Bool {
        walkthroughEngine.isRunning || companionManager.voiceState != .idle
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
                    LumaOnboardingWindowManager.shared.showOnboardingWindow()
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
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 0) {
            permissionsHeroSection

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)
                .padding(.bottom, 4)

            permissionItemRow(
                label: "Microphone",
                subtitle: "Used only when you press Ctrl+Option",
                iconName: "mic",
                iconColor: Color(hex: "#3B82F6"),
                isGranted: companionManager.hasMicrophonePermission,
                grantAction: { grantMicrophonePermission() }
            )

            permissionItemRow(
                label: "Accessibility",
                subtitle: "Points at elements on your screen",
                iconName: "hand.raised",
                iconColor: Color(hex: "#8B5CF6"),
                isGranted: companionManager.hasAccessibilityPermission,
                grantAction: { WindowPositionManager.requestAccessibilityPermission() }
            )

            permissionItemRow(
                label: "Screen Recording",
                subtitle: "Quit and reopen after granting",
                iconName: "rectangle.dashed.badge.record",
                iconColor: Color(hex: "#EC4899"),
                isGranted: companionManager.hasScreenRecordingPermission,
                grantAction: { WindowPositionManager.requestScreenRecordingPermission() }
            )

            if companionManager.hasScreenRecordingPermission {
                permissionItemRow(
                    label: "Screen Content",
                    subtitle: "Required for element detection",
                    iconName: "eye",
                    iconColor: Color(hex: "#F59E0B"),
                    isGranted: companionManager.hasScreenContentPermission,
                    grantAction: { companionManager.requestScreenContentPermission() }
                )
            }
        }
    }

    /// Hero header for the permissions section: blue bulb icon, title, and animated progress bar.
    private var permissionsHeroSection: some View {
        let grantedCount = [
            companionManager.hasMicrophonePermission,
            companionManager.hasAccessibilityPermission,
            companionManager.hasScreenRecordingPermission,
            // Screen content only counts if screen recording is also granted (it unlocks after)
            companionManager.hasScreenRecordingPermission && companionManager.hasScreenContentPermission,
        ].filter { $0 }.count
        let totalRequired = companionManager.hasScreenRecordingPermission ? 4 : 3

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Blue gradient bulb icon — same style as HTML PermissionsPanel header
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(hex: "#3380FF"), Color(hex: "#1D4ED8")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                        .shadow(color: Color(hex: "#2563EB").opacity(0.35), radius: 10, y: 4)

                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Luma needs access")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Grant permissions to get started")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            // Progress bar: accent → purple gradient, fills based on grant count
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DS.Colors.surface3)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [DS.Colors.accent, Color(hex: "#8F46EB")],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: max(0, proxy.size.width * CGFloat(grantedCount) / CGFloat(totalRequired)))
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: grantedCount)
                    }
                }
                .frame(height: 5)

                Text("\(grantedCount) of \(totalRequired) granted")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.bottom, 12)
    }

    /// Renders a single permission row with a colored icon circle, labels, and a Grant or Granted indicator.
    private func permissionItemRow(
        label: String,
        subtitle: String,
        iconName: String,
        iconColor: Color,
        isGranted: Bool,
        grantAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // Colored icon container — subtle fill + border at the permission's accent color
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(iconColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(iconColor.opacity(0.22), lineWidth: 1)
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isGranted ? iconColor : DS.Colors.textTertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isGranted ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button(action: grantAction) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(iconColor))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    /// Requests microphone permission via the native macOS dialog, or opens System Settings if already denied.
    private func grantMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
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
        // Full-width clickable card showing the active model and its provider.
        // Tapping opens Settings so the user can change the model.
        let activeModelID = ProfileManager.shared.activeProfile?.selectedModel ?? ""
        let displayModelName = activeModelID.isEmpty ? "No model set" : activeModelID
        let providerName = extractProviderName(from: activeModelID)

        return Button(action: openSettingsWithPINCheck) {
            HStack(spacing: 8) {
                // CPU chip icon signals this is a model/compute setting
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Text(displayModelName)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Provider pill — accentSubtle background, accentText color
                Text(providerName)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.accentSubtle))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Change model in Settings")
        .lumaFadeUp()
    }

    /// Extracts a short provider display name from an OpenRouter or direct model ID.
    /// OpenRouter IDs use "provider/model-name" format; direct IDs use the model prefix.
    private func extractProviderName(from modelID: String) -> String {
        guard !modelID.isEmpty else { return "—" }
        if let slashIndex = modelID.firstIndex(of: "/") {
            let prefix = String(modelID[modelID.startIndex..<slashIndex]).lowercased()
            switch prefix {
            case "anthropic":           return "Anthropic"
            case "google":              return "Google"
            case "openai":              return "OpenAI"
            case "meta-llama", "meta":  return "Meta"
            case "mistralai", "mistral": return "Mistral"
            case "cohere":              return "Cohere"
            case "deepseek":            return "DeepSeek"
            default:                    return prefix.prefix(1).uppercased() + prefix.dropFirst()
            }
        }
        // No slash — infer from model name prefix
        if modelID.hasPrefix("claude")  { return "Anthropic" }
        if modelID.hasPrefix("gpt") || modelID.hasPrefix("o1") || modelID.hasPrefix("o3") { return "OpenAI" }
        if modelID.hasPrefix("gemini")  { return "Google" }
        return "—"
    }

    // MARK: - Bottom Bar

    /// Bottom bar: avatar + username on the left, settings gear + quit on the right.
    /// Surface1 background with a 1pt top border for visual separation from the panel body.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            // Left: avatar circle showing user's initials from AccountManager
            if let account = accountManager.currentAccount {
                LumaAvatarView(initials: account.avatarInitials, size: 28)

                // Username shown next to avatar for quick context
                Text(account.username.isEmpty ? account.displayName : account.username)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1)
        .overlay(
            // 1pt top border separating the bottom bar from the panel body
            Rectangle()
                .frame(height: 1)
                .foregroundColor(DS.Colors.borderSubtle),
            alignment: .top
        )
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
        if walkthroughEngine.isRunning {
            // Blue pulsing dot while the walkthrough is executing
            return DS.Colors.accentText
        }
        if !companionManager.isOverlayVisible {
            return DS.Colors.success
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .processing, .responding:
            return DS.Colors.accentText
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if walkthroughEngine.isRunning {
            return "Walking…"
        }
        if companionManager.isAgentModeEnabled {
            return "Agent mode"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
