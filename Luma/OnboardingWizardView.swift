//
//  OnboardingWizardView.swift
//  leanring-buddy
//
//  Full-screen 5-step onboarding wizard shown on first launch.
//  Covers welcome, account creation, PIN setup, API profile setup, and a done screen.
//  The caller passes a binding to `hasCompletedOnboarding` so this view can dismiss itself
//  when onboarding finishes without needing a global state manager.
//

import SwiftUI

// MARK: - OnboardingWizardView

@MainActor
struct OnboardingWizardView: View {

    /// Binding owned by the caller (e.g. CompanionPanelView or the app root).
    /// Set to true on the final step to dismiss the wizard.
    @Binding var hasCompletedOnboarding: Bool

    /// Which of the 5 steps (0–4) is currently visible.
    @State private var currentStep: Int = 0
    /// Direction of the last navigation — drives the slide transition edge.
    /// Forward navigation slides new content in from the trailing edge;
    /// backward navigation slides it in from the leading edge.
    @State private var isNavigatingForward: Bool = true
    /// The running CompanionManager instance — passed in by the window manager.
    /// Needed so permission steps can read live permission state via @Published properties.
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar — step navigation matching the settings window sidebar pattern.
            // Shows which steps are done (green check), active (blue circle), or future (dim).
            onboardingSidebarView

            // Vertical separator — same border token used throughout the app.
            Rectangle()
                .fill(Color(hex: "#2E322E"))
                .frame(width: 1)

            // Right content area: step view fills available height, bottom nav below it.
            VStack(spacing: 0) {
                stepContentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom nav: back + step counter. Only visible on middle steps (not welcome or done).
                if currentStep > 0 && currentStep < 6 {
                    bottomNavigationRow
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: "#0E0F0E"))
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color(hex: "#141614"))
        .focusEffectDisabled()
    }

    // MARK: - Sidebar

    /// Left sidebar with step indicators mirroring the HTML OnboardingWizard design.
    /// Each step shows a circle (done=green check, active=blue number, future=dim number),
    /// a label, and a highlight row for the active step.
    private var onboardingSidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App name header
            Text("Luma")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color(hex: "#ECEEED"))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

            // Step list
            VStack(spacing: 2) {
                ForEach(Array(onboardingStepNames.enumerated()), id: \.offset) { stepIndex, stepName in
                    onboardingSidebarStepRow(stepIndex: stepIndex, stepName: stepName)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // Version footer
            Text("Built by Nox")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#555D58"))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(width: 200)
        .background(Color(hex: "#141614"))
    }

    /// Human-readable sidebar step names — one per wizard step (indices 0–6).
    private let onboardingStepNames = ["Welcome", "Account", "Security", "API Setup", "Permissions", "Demo", "Done"]

    /// Renders a single sidebar step row with the correct visual state.
    private func onboardingSidebarStepRow(stepIndex: Int, stepName: String) -> some View {
        let isStepDone = stepIndex < currentStep
        let isStepActive = stepIndex == currentStep
        let isStepFuture = stepIndex > currentStep

        return HStack(spacing: 10) {
            // Indicator square: check when done, filled when active, dim when future.
            ZStack {
                Rectangle()
                    .fill(isStepDone
                          ? Color(hex: "#34D399")
                          : isStepActive ? Color(hex: "#FFFFFF") : Color(hex: "#282B28"))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Rectangle()
                            .stroke(
                                isStepDone ? Color(hex: "#34D399")
                                           : isStepActive ? Color(hex: "#FFFFFF") : Color(hex: "#3A3F3A"),
                                lineWidth: 1
                            )
                    )

                if isStepDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black)
                } else {
                    Text("\(stepIndex + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isStepActive ? .black : Color(hex: "#555D58"))
                }
            }

            Text(stepName)
                .font(.system(size: 12, weight: isStepActive ? .semibold : .regular))
                .foregroundColor(
                    isStepDone   ? Color(hex: "#9BA39D") :
                    isStepActive ? Color(hex: "#ECEEED") :
                                   Color(hex: "#555D58")
                )
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isStepActive ? Color(hex: "#FFFFFF").opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) {
            if isStepActive {
                Rectangle()
                    .fill(Color(hex: "#FFFFFF"))
                    .frame(width: 2)
            }
        }
        .opacity(isStepFuture ? 0.35 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: currentStep)
    }

    // MARK: - Step Content Router

    /// Renders the correct step view based on `currentStep`.
    /// Uses `.id(currentStep)` so SwiftUI replaces the entire view on step change,
    /// firing the entrance animation. Direction is captured from `isNavigatingForward`:
    /// forward steps slide in from the trailing edge; back steps from the leading edge.
    @ViewBuilder
    private var stepContentView: some View {
        // Compute edge offsets before entering the ViewBuilder group so they're
        // available at the time SwiftUI evaluates the transition closure.
        let insertionOffset: CGFloat = isNavigatingForward ? 40 : -40
        let removalOffset: CGFloat = isNavigatingForward ? -40 : 40

        Group {
            switch currentStep {
            case 0:
                OnboardingWelcomeStep(onGetStarted: advanceToNextStep)
            case 1:
                OnboardingAccountCreationStep(onAccountCreated: advanceToNextStep)
            case 2:
                OnboardingPINSetupStep(onPINStepComplete: advanceToNextStep)
            case 3:
                OnboardingAPIProfileStep(onProfileSaved: advanceToNextStep)
            case 4:
                // Permissions gate — Continue only enabled when all three permissions are granted.
                OnboardingPermissionsStep(
                    companionManager: companionManager,
                    onAllPermissionsGranted: advanceToNextStep
                )
            case 5:
                OnboardingDemoStep(onSkipOrContinue: advanceToNextStep)
            case 6:
                OnboardingDoneStep(onStartLearning: completeOnboarding)
            default:
                // Should never be reached, but prevents a blank view if state is invalid
                EmptyView()
            }
        }
        .id(currentStep)
        .transition(.asymmetric(
            insertion: .offset(x: insertionOffset).combined(with: .opacity),
            removal:   .offset(x: removalOffset).combined(with: .opacity)
        ))
        .animation(.spring(response: 0.40, dampingFraction: 0.86), value: currentStep)
    }

    // MARK: - Bottom Navigation Row

    /// Bottom bar shown only on middle steps (1–5): back button on the left,
    /// step counter on the right. Styled to match the HTML design's border-top separator.
    private var bottomNavigationRow: some View {
        HStack {
            backButton

            Spacer()

            // Step counter — "Step N of 5" where N is the current middle step (1–4).
            // The wizard has 6 steps total (0–5); welcome (0) and done (5) hide this bar.
            Text("Step \(currentStep) of 6")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#555D58"))
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 14)
        .background(Color(hex: "#0E0F0E"))
        .overlay(
            Rectangle()
                .fill(Color(hex: "#2E322E"))
                .frame(height: 1),
            alignment: .top
        )
    }

    private var backButton: some View {
        Button(action: goBackToPreviousStep) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 12, weight: .medium))
                Text("Back")
                    .font(.system(size: 12))
            }
            .foregroundColor(Color(hex: "#9BA39D"))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Navigation Actions

    private func advanceToNextStep() {
        // Set direction before the step changes so the transition captures the correct edge.
        isNavigatingForward = true
        withAnimation(.spring(response: 0.40, dampingFraction: 0.86)) {
            currentStep += 1
        }
    }

    private func goBackToPreviousStep() {
        isNavigatingForward = false
        withAnimation(.spring(response: 0.40, dampingFraction: 0.86)) {
            currentStep -= 1
        }
    }

    /// Called on the final step. Persists the completion flag, requests accessibility
    /// permission (deferred from launch so it doesn't clash with onboarding), then closes
    /// the dedicated onboarding window via LumaOnboardingWindowManager.
    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        hasCompletedOnboarding = true
        // Now that setup is complete, ask for accessibility. Doing this here instead of
        // at app launch prevents the permission dialog from appearing over the onboarding wizard.
        AccessibilityWatcher.shared.checkAndRequestPermission()
        // Close the onboarding window now that setup is finished.
        LumaOnboardingWindowManager.shared.hideOnboardingWindow()
    }
}

// MARK: - Step 0: Welcome

/// First screen. Shows the Luma icon, tagline, and a single "Get Started" button.
@MainActor
private struct OnboardingWelcomeStep: View {

    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Luma lightbulb icon — same symbol used in the menu bar
            Image(systemName: LumaTheme.MenuBar.iconName)
                .font(.system(size: 72))
                .foregroundColor(LumaTheme.Colors.accent)
                .padding(.bottom, 32)

            VStack(spacing: LumaTheme.Spacing.md) {
                Text(LumaStrings.App.tagline)
                    .font(LumaTheme.Typography.largeTitle)
                    .foregroundColor(LumaTheme.Colors.primaryText)
                    .multilineTextAlignment(.center)

                Text("Your always-on learning companion.")
                    .font(LumaTheme.Typography.body)
                    .foregroundColor(LumaTheme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            OnboardingPrimaryButton(
                label: "\(LumaStrings.Onboarding.getStarted) →",
                action: onGetStarted
            )
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Step 1: Account Creation

/// Collects username and display name. Validates before creating the account.
@MainActor
private struct OnboardingAccountCreationStep: View {

    let onAccountCreated: () -> Void

    @State private var enteredUsername: String = ""
    @State private var enteredDisplayName: String = ""

    /// Non-nil when there is a validation error to show beneath the fields.
    @State private var validationErrorMessage: String? = nil

    /// True while the account is being saved (prevents double-tap)
    @State private var isSavingAccount: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: LumaTheme.Spacing.md) {
                Text(LumaStrings.Onboarding.accountTitle)
                    .font(LumaTheme.Typography.largeTitle)
                    .foregroundColor(LumaTheme.Colors.primaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 32)

            VStack(spacing: LumaTheme.Spacing.lg) {
                // Username field — lowercase, no spaces
                VStack(alignment: .leading, spacing: LumaTheme.Spacing.xs) {
                    TextField("username", text: $enteredUsername)
                        .textFieldStyle(.plain)
                        .tint(Color.white)
                        .font(LumaTheme.Typography.body)
                        .foregroundColor(LumaTheme.Colors.primaryText)
                        .padding(LumaTheme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                                .fill(LumaTheme.Colors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                                .stroke(LumaTheme.Colors.surfaceElevated, lineWidth: 1)
                        )
                        // Enforce lowercase as the user types
                        .onChange(of: enteredUsername) { _, newValue in
                            enteredUsername = newValue.lowercased()
                        }
                }

                // Display name field
                TextField("Your name", text: $enteredDisplayName)
                    .textFieldStyle(.plain)
                    .tint(Color.white)
                    .font(LumaTheme.Typography.body)
                    .foregroundColor(LumaTheme.Colors.primaryText)
                    .padding(LumaTheme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                            .fill(LumaTheme.Colors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                            .stroke(LumaTheme.Colors.surfaceElevated, lineWidth: 1)
                    )

                // Validation error message shown only when something is wrong
                if let errorMessage = validationErrorMessage {
                    Text(errorMessage)
                        .font(LumaTheme.Typography.caption)
                        .foregroundColor(LumaTheme.Colors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()

            OnboardingPrimaryButton(
                label: "Continue",
                isLoading: isSavingAccount,
                action: handleContinueTapped
            )
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Validation & Account Creation

    private func handleContinueTapped() {
        // Clear any previous error before re-validating
        validationErrorMessage = nil

        let trimmedUsername = enteredUsername.trimmingCharacters(in: .whitespaces)
        let trimmedDisplayName = enteredDisplayName.trimmingCharacters(in: .whitespaces)

        // Username must be non-empty and must not contain any spaces
        guard !trimmedUsername.isEmpty else {
            validationErrorMessage = "Username is required."
            return
        }
        guard !trimmedUsername.contains(" ") else {
            validationErrorMessage = "Username cannot contain spaces."
            return
        }

        guard !trimmedDisplayName.isEmpty else {
            validationErrorMessage = "Display name is required."
            return
        }

        // All validation passed — create the account and advance
        isSavingAccount = true
        AccountManager.shared.createAccount(
            username: trimmedUsername,
            displayName: trimmedDisplayName
        )
        isSavingAccount = false
        onAccountCreated()
    }
}

// MARK: - Step 2: PIN Setup

/// Optional PIN protection step. User can set a PIN or skip.
/// If "Set PIN" is tapped, PINEntryView is shown as an overlay on top of this step.
@MainActor
private struct OnboardingPINSetupStep: View {

    let onPINStepComplete: () -> Void

    /// Controls whether the PINEntryView overlay is currently visible
    @State private var isShowingPINEntryOverlay: Bool = false

    var body: some View {
        ZStack {
            // Base content — always visible behind the overlay
            pinSetupBaseContent

            // PIN entry overlay — shown when user taps "Set PIN"
            if isShowingPINEntryOverlay {
                pinEntryOverlay
            }
        }
    }

    private var pinSetupBaseContent: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: LumaTheme.Spacing.md) {
                Text(LumaStrings.Onboarding.pinTitle)
                    .font(LumaTheme.Typography.largeTitle)
                    .foregroundColor(LumaTheme.Colors.primaryText)
                    .multilineTextAlignment(.center)

                Text(LumaStrings.Onboarding.pinSubtitle)
                    .font(LumaTheme.Typography.body)
                    .foregroundColor(LumaTheme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: LumaTheme.Spacing.md) {
                OnboardingPrimaryButton(label: "Set PIN") {
                    isShowingPINEntryOverlay = true
                }

                OnboardingSecondaryButton(label: LumaStrings.Onboarding.pinSkip) {
                    // User chose not to set a PIN — advance without one
                    onPINStepComplete()
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    /// Full-screen translucent overlay that hosts PINEntryView.
    /// Shown on top of the base content so the step context stays visible underneath.
    private var pinEntryOverlay: some View {
        ZStack {
            // Semi-transparent scrim behind the PIN entry card
            LumaTheme.Colors.background.opacity(0.92)
                .ignoresSafeArea()

            // PIN entry card
            VStack {
                PINEntryView(
                    mode: .set,
                    title: LumaStrings.PIN.setPIN,
                    onSuccess: {
                        // PIN was set successfully — dismiss overlay and advance
                        isShowingPINEntryOverlay = false
                        onPINStepComplete()
                    },
                    onCancel: {
                        // User cancelled out of PIN setup — dismiss overlay, stay on this step
                        isShowingPINEntryOverlay = false
                    }
                )
                .background(
                    RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.extraLarge)
                        .fill(LumaTheme.Colors.background)
                        .shadow(color: LumaTheme.background.opacity(0.1), radius: 20, x: 0, y: 8)
                )
                .frame(maxWidth: 360)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: LumaTheme.Animation.standard), value: isShowingPINEntryOverlay)
    }
}

// MARK: - Step 3: API Profile Setup

/// Collects AI provider, API key, and optional base URL (for Custom).
/// Validates the key with a lightweight test request before allowing the user to continue.
@MainActor
private struct OnboardingAPIProfileStep: View {

    let onProfileSaved: () -> Void

    @State private var selectedProvider: LumaAPIProvider = .openRouter
    @State private var enteredAPIKey: String = ""
    @State private var isAPIKeyVisible: Bool = false
    @State private var enteredCustomBaseURL: String = ""

    /// Tracks the result of the test connection attempt
    enum ConnectionTestStatus: Equatable {
        case untested
        case testing
        case success
        case failure(errorDescription: String)
    }
    @State private var connectionTestStatus: ConnectionTestStatus = .untested

    /// True while the profile is being saved (prevents double-tap)
    @State private var isSavingProfile: Bool = false

    // MARK: - Default Models per Provider

    /// Returns the recommended default model for the given provider.
    private func defaultModel(forProvider provider: LumaAPIProvider) -> String {
        switch provider {
        case .openRouter: return "google/gemini-2.5-flash:free"
        case .anthropic:  return "claude-sonnet-4-6"
        case .google:     return "gemini-2.0-flash"
        case .custom:     return ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: LumaTheme.Spacing.md) {
                    Text(LumaStrings.Onboarding.apiTitle)
                        .font(LumaTheme.Typography.largeTitle)
                        .foregroundColor(LumaTheme.Colors.primaryText)
                        .multilineTextAlignment(.center)

                    Text(LumaStrings.Onboarding.apiSubtitle)
                        .font(LumaTheme.Typography.body)
                        .foregroundColor(LumaTheme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)
                .padding(.bottom, LumaTheme.Spacing.xxl)

                // Provider Picker (segmented control style)
                providerPickerView
                    .padding(.bottom, LumaTheme.Spacing.xxl)

                // API key field with eye toggle
                apiKeyFieldView
                    .padding(.bottom, LumaTheme.Spacing.xl)

                // Base URL field — only shown for Custom provider
                if selectedProvider == .custom {
                    customBaseURLFieldView
                        .padding(.bottom, LumaTheme.Spacing.xl)
                }

                // Test connection button + status indicator
                testConnectionSection
                    .padding(.bottom, LumaTheme.Spacing.xl)

                // Continue button — disabled until an API key has been entered
                OnboardingPrimaryButton(
                    label: "Continue",
                    isDisabled: enteredAPIKey.trimmingCharacters(in: .whitespaces).isEmpty,
                    isLoading: isSavingProfile,
                    action: handleContinueTapped
                )
                .padding(.bottom, 56)
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        // Reset connection test whenever provider or key changes so the status isn't stale
        .onChange(of: selectedProvider) { _, _ in
            connectionTestStatus = .untested
        }
        .onChange(of: enteredAPIKey) { _, _ in
            connectionTestStatus = .untested
        }
    }

    // MARK: - Subviews

    private var providerPickerView: some View {
        Picker("Provider", selection: $selectedProvider) {
            ForEach(LumaAPIProvider.allCases, id: \.self) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var apiKeyFieldView: some View {
        VStack(alignment: .leading, spacing: LumaTheme.Spacing.xs) {
            Text("API Key")
                .font(LumaTheme.Typography.bodyMedium)
                .foregroundColor(LumaTheme.Colors.primaryText)

            HStack(spacing: LumaTheme.Spacing.sm) {
                // Toggle between secure (hidden) and plain (visible) API key input
                if isAPIKeyVisible {
                    TextField("Paste your API key", text: $enteredAPIKey)
                        .textFieldStyle(.plain)
                        .tint(Color.white)
                        .font(LumaTheme.Typography.body)
                        .foregroundColor(LumaTheme.Colors.primaryText)
                } else {
                    SecureField("Paste your API key", text: $enteredAPIKey)
                        .textFieldStyle(.plain)
                        .tint(Color.white)
                        .font(LumaTheme.Typography.body)
                        .foregroundColor(LumaTheme.Colors.primaryText)
                }

                // Eye button to reveal or conceal the key
                Button(action: { isAPIKeyVisible.toggle() }) {
                    Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                        .font(LumaTheme.Typography.body)
                        .foregroundColor(LumaTheme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(LumaTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                    .fill(LumaTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                    .stroke(LumaTheme.Colors.surfaceElevated, lineWidth: 1)
            )
        }
    }

    private var customBaseURLFieldView: some View {
        VStack(alignment: .leading, spacing: LumaTheme.Spacing.xs) {
            Text("Base URL")
                .font(LumaTheme.Typography.bodyMedium)
                .foregroundColor(LumaTheme.Colors.primaryText)

            TextField("https://your-provider.com/v1", text: $enteredCustomBaseURL)
                .textFieldStyle(.plain)
                .tint(Color.white)
                .font(LumaTheme.Typography.body)
                .foregroundColor(LumaTheme.Colors.primaryText)
                .padding(LumaTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                        .fill(LumaTheme.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.medium)
                        .stroke(LumaTheme.Colors.surfaceElevated, lineWidth: 1)
                )
        }
    }

    private var testConnectionSection: some View {
        VStack(spacing: LumaTheme.Spacing.sm) {
            OnboardingSecondaryButton(
                label: connectionTestStatus == .testing ? "Testing…" : "Test Connection",
                isDisabled: enteredAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
                         || connectionTestStatus == .testing,
                action: handleTestConnectionTapped
            )

            // Show connection result text beneath the button
            switch connectionTestStatus {
            case .untested, .testing:
                EmptyView()
            case .success:
                Label("Connected", systemImage: "checkmark")
                    .font(LumaTheme.Typography.caption)
                    .foregroundColor(LumaTheme.Colors.success)
            case .failure(let errorDescription):
                Label("Failed: \(errorDescription)", systemImage: "xmark")
                    .font(LumaTheme.Typography.caption)
                    .foregroundColor(LumaTheme.Colors.error)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Actions

    private func handleTestConnectionTapped() {
        connectionTestStatus = .testing

        // Capture values to pass into the detached task
        let apiKeyToTest = enteredAPIKey.trimmingCharacters(in: .whitespaces)
        let providerToTest = selectedProvider
        let customBaseURLToTest = enteredCustomBaseURL.trimmingCharacters(in: .whitespaces)

        Task {
            let result = await performLightweightConnectionTest(
                provider: providerToTest,
                apiKey: apiKeyToTest,
                customBaseURL: customBaseURLToTest
            )
            connectionTestStatus = result
        }
    }

    private func handleContinueTapped() {
        isSavingProfile = true

        let trimmedAPIKey = enteredAPIKey.trimmingCharacters(in: .whitespaces)
        let profileBaseURL = selectedProvider == .custom
            ? enteredCustomBaseURL.trimmingCharacters(in: .whitespaces)
            : ""

        // Build a profile name from the provider for easy identification
        let profileName = "\(selectedProvider.displayName) Profile"
        let modelForProvider = defaultModel(forProvider: selectedProvider)

        let newProfile = LumaAPIProfile(
            name: profileName,
            provider: selectedProvider,
            baseURL: profileBaseURL,
            isDefault: true,
            selectedModel: modelForProvider
        )

        // Add profile metadata first (ProfileManager.saveAPIKey requires the profile to exist)
        ProfileManager.shared.addProfile(newProfile)

        // Save the API key to Keychain under this profile's identifier
        try? ProfileManager.shared.saveAPIKey(trimmedAPIKey, forProfileID: newProfile.id)

        isSavingProfile = false
        onProfileSaved()
    }

    // MARK: - Connection Test

    /// GETs the provider's models list endpoint to verify the API key is valid.
    /// Returns a `ConnectionTestStatus` result. Does NOT use ProfileManager or APIClient
    /// because the profile hasn't been fully saved yet at this point.
    private func performLightweightConnectionTest(
        provider: LumaAPIProvider,
        apiKey: String,
        customBaseURL: String
    ) async -> ConnectionTestStatus {

        // Each provider exposes a GET /models endpoint for lightweight key validation
        let modelsEndpointURLString: String
        switch provider {
        case .openRouter:
            modelsEndpointURLString = "https://openrouter.ai/api/v1/models"
        case .anthropic:
            modelsEndpointURLString = "https://api.anthropic.com/v1/models"
        case .google:
            modelsEndpointURLString = "https://generativelanguage.googleapis.com/v1beta/models"
        case .custom:
            let trimmedBaseURL = customBaseURL.trimmingCharacters(in: .whitespaces)
            let baseURL = trimmedBaseURL.isEmpty ? provider.defaultBaseURL : trimmedBaseURL
            modelsEndpointURLString = baseURL + "/models"
        }

        guard let endpointURL = URL(string: modelsEndpointURLString) else {
            return .failure(errorDescription: "Invalid URL")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        // Each provider uses a different auth header:
        // Anthropic: x-api-key (no Bearer prefix) + required anthropic-version header
        // Google: x-goog-api-key (the /v1beta/models endpoint uses this header, not Authorization)
        // All others: Authorization: Bearer
        if provider == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if provider == .google {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, httpResponse) = try await URLSession.shared.data(for: request)

            guard let statusCodeResponse = httpResponse as? HTTPURLResponse else {
                return .failure(errorDescription: "Invalid response")
            }

            // A 200 response means the key is valid
            if statusCodeResponse.statusCode == 200 {
                return .success
            } else {
                return .failure(errorDescription: "HTTP \(statusCodeResponse.statusCode)")
            }
        } catch {
            return .failure(errorDescription: error.localizedDescription)
        }
    }
}

// MARK: - Step 4: Done

/// Final confirmation screen with an animated checkmark.
@MainActor
private struct OnboardingDoneStep: View {

    let onStartLearning: () -> Void

    /// Controls the scale-in animation of the checkmark on appear
    @State private var checkmarkScaleAmount: CGFloat = 0.5
    @State private var checkmarkOpacityAmount: Double = 0.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Animated green checkmark — scale-in on appear for a satisfying completion feel
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(LumaTheme.Colors.success)
                .scaleEffect(checkmarkScaleAmount)
                .opacity(checkmarkOpacityAmount)
                .padding(.bottom, 32)
                .onAppear {
                    // Animate from small/invisible to full size over 0.4s
                    withAnimation(.spring(response: LumaTheme.Animation.slow, dampingFraction: 0.6)) {
                        checkmarkScaleAmount = 1.0
                        checkmarkOpacityAmount = 1.0
                    }
                }

            VStack(spacing: LumaTheme.Spacing.md) {
                Text(LumaStrings.Onboarding.doneTitle)
                    .font(LumaTheme.Typography.largeTitle)
                    .foregroundColor(LumaTheme.Colors.primaryText)
                    .multilineTextAlignment(.center)

                Text(LumaStrings.Companion.pushToTalkHint)
                    .font(LumaTheme.Typography.body)
                    .foregroundColor(LumaTheme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            OnboardingPrimaryButton(
                label: LumaStrings.Onboarding.startLearning,
                action: onStartLearning
            )
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared Button Components

/// Full-width black button with white text — used for primary actions in the onboarding flow.
@MainActor
private struct OnboardingPrimaryButton: View {

    let label: String
    var isDisabled: Bool = false
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: {
            guard !isDisabled && !isLoading else { return }
            action()
        }) {
            HStack(spacing: LumaTheme.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .tint(LumaTheme.Colors.accentForeground)
                }
                Text(label)
                    .font(LumaTheme.Typography.bodyMedium)
                    .foregroundColor(LumaTheme.Colors.accentForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LumaTheme.Spacing.md)
            .padding(.horizontal, LumaTheme.Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.large)
                    .fill(isDisabled
                          ? LumaTheme.Colors.tertiaryText
                          : (isHovering ? LumaTheme.Colors.accent.opacity(0.85) : LumaTheme.Colors.accent))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .onHover { hovering in
            isHovering = hovering
            if hovering && !isDisabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// Full-width button with a light gray border and dark text — used for secondary actions.
@MainActor
private struct OnboardingSecondaryButton: View {

    let label: String
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: {
            guard !isDisabled else { return }
            action()
        }) {
            Text(label)
                .font(LumaTheme.Typography.bodyMedium)
                .foregroundColor(isDisabled ? LumaTheme.Colors.tertiaryText : LumaTheme.Colors.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LumaTheme.Spacing.md)
                .padding(.horizontal, LumaTheme.Spacing.xl)
                .background(
                    RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.large)
                        .fill(isHovering && !isDisabled
                              ? LumaTheme.Colors.surfaceElevated
                              : LumaTheme.Colors.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LumaTheme.CornerRadius.large)
                        .stroke(LumaTheme.Colors.surfaceElevated, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovering = hovering
            if hovering && !isDisabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

