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

    var body: some View {
        ZStack {
            // Full-screen white background
            LumaTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Main step content area — fills available space above the nav row
                stepContentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom navigation: back button + progress dots
                bottomNavigationRow
                    .padding(.top, LumaTheme.Spacing.xl)
                    .padding(.bottom, LumaTheme.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusEffectDisabled()
    }

    // MARK: - Step Content Router

    /// Renders the correct step view based on `currentStep`.
    /// Uses `.id(currentStep)` on the outer container so SwiftUI creates a fresh view
    /// whenever the step changes, ensuring entrance animations fire correctly.
    @ViewBuilder
    private var stepContentView: some View {
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
                OnboardingDoneStep(onStartLearning: completeOnboarding)
            default:
                // Should never be reached, but prevents a blank view if state is invalid
                EmptyView()
            }
        }
        .id(currentStep)
        .transition(.opacity)
        .animation(.easeInOut(duration: LumaTheme.Animation.standard), value: currentStep)
    }

    // MARK: - Bottom Navigation Row

    /// Shows a back button on the left and progress dots centered below the content.
    /// Back is hidden on step 0 (welcome) and step 4 (done) — no going back from those.
    private var bottomNavigationRow: some View {
        ZStack {
            // Progress dots are always centered regardless of whether back is shown
            progressDotsView

            // Back button floats to the left only on middle steps
            if currentStep > 0 && currentStep < 4 {
                HStack {
                    backButton
                    Spacer()
                }
            }
        }
        .padding(.horizontal, LumaTheme.Spacing.xl)
    }

    private var backButton: some View {
        Button(action: goBackToPreviousStep) {
            HStack(spacing: LumaTheme.Spacing.xs) {
                Image(systemName: "arrow.left")
                    .font(LumaTheme.Typography.bodyMedium)
                Text("Back")
                    .font(LumaTheme.Typography.body)
            }
            .foregroundColor(LumaTheme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var progressDotsView: some View {
        HStack(spacing: LumaTheme.Spacing.sm) {
            ForEach(0..<5, id: \.self) { dotIndex in
                Circle()
                    .fill(dotIndex <= currentStep
                          ? LumaTheme.Colors.accent
                          : LumaTheme.Colors.tertiaryText)
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - Navigation Actions

    private func advanceToNextStep() {
        withAnimation(.easeInOut(duration: LumaTheme.Animation.standard)) {
            currentStep += 1
        }
    }

    private func goBackToPreviousStep() {
        withAnimation(.easeInOut(duration: LumaTheme.Animation.standard)) {
            currentStep -= 1
        }
    }

    /// Called on the final step. Persists the completion flag, requests accessibility
    /// permission (deferred from launch so it doesn't clash with onboarding), then dismisses.
    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        hasCompletedOnboarding = true
        // Now that setup is complete, ask for accessibility. Doing this here instead of
        // at app launch prevents the permission dialog from appearing over the onboarding wizard.
        AccessibilityWatcher.shared.checkAndRequestPermission()
    }
}

// MARK: - Step 0: Welcome

/// First screen. Shows the Luma icon, tagline, and a single "Get Started" button.
@MainActor
private struct OnboardingWelcomeStep: View {

    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: LumaTheme.Spacing.xl) {
            Spacer()

            // Luma lightbulb icon — same symbol used in the menu bar
            Image(systemName: LumaTheme.MenuBar.iconName)
                .font(.system(size: 72))
                .foregroundColor(LumaTheme.Colors.accent)

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
        }
        .padding(.horizontal, LumaTheme.Spacing.xxl)
        .frame(maxWidth: 480)
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
        VStack(spacing: LumaTheme.Spacing.xl) {
            Spacer()

            VStack(spacing: LumaTheme.Spacing.md) {
                Text(LumaStrings.Onboarding.accountTitle)
                    .font(LumaTheme.Typography.largeTitle)
                    .foregroundColor(LumaTheme.Colors.primaryText)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: LumaTheme.Spacing.lg) {
                // Username field — lowercase, no spaces
                VStack(alignment: .leading, spacing: LumaTheme.Spacing.xs) {
                    TextField("username", text: $enteredUsername)
                        .textFieldStyle(.plain)
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
        }
        .padding(.horizontal, LumaTheme.Spacing.xxl)
        .frame(maxWidth: 480)
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
        VStack(spacing: LumaTheme.Spacing.xl) {
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
        }
        .padding(.horizontal, LumaTheme.Spacing.xxl)
        .frame(maxWidth: 480)
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
                .padding(.bottom, 48)
            }
            .padding(.horizontal, LumaTheme.Spacing.xxl)
            .frame(maxWidth: 480)
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
                        .font(LumaTheme.Typography.body)
                        .foregroundColor(LumaTheme.Colors.primaryText)
                } else {
                    SecureField("Paste your API key", text: $enteredAPIKey)
                        .textFieldStyle(.plain)
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
                Text("✓ Connected")
                    .font(LumaTheme.Typography.caption)
                    .foregroundColor(LumaTheme.Colors.success)
            case .failure(let errorDescription):
                Text("✗ Failed: \(errorDescription)")
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
        VStack(spacing: LumaTheme.Spacing.xl) {
            Spacer()

            // Animated green checkmark — scale-in on appear for a satisfying completion feel
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(LumaTheme.Colors.success)
                .scaleEffect(checkmarkScaleAmount)
                .opacity(checkmarkOpacityAmount)
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
        }
        .padding(.horizontal, LumaTheme.Spacing.xxl)
        .frame(maxWidth: 480)
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
