//
//  SettingsPanelView.swift
//  leanring-buddy
//
//  4-tab settings panel presented as a sheet from the menu bar panel.
//  Tabs: Account, API Profiles, Model, General.
//

import SwiftUI

// MARK: - SettingsPanelView

@MainActor
struct SettingsPanelView: View {

    @Environment(\.dismiss) private var dismiss

    // Observe singletons so changes in each tab update the UI immediately.
    @StateObject private var accountManager = AccountManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var pinManager    = PINManager.shared

    /// Which tab is currently selected.
    @State private var selectedTab: SettingsTab = .account

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()
                .background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsHeader
                    selectedTabContent
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Colors.background)
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(DS.Colors.background)
        .focusEffectDisabled()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { closeSettingsPanel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focusEffectDisabled()
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .padding(.trailing, 24) //24 points for margin right

            }
        }
    }

    private func closeSettingsPanel() {
        LumaSettingsWindowManager.shared.hideSettingsWindow()
        dismiss()
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
//            Text("Luma Settings")
//                .font(.system(size: 18, weight: .semibold))
//                .foregroundColor(DS.Colors.textPrimary)
//                .padding(.horizontal, 14)
//                .padding(.top, 18)
//                .padding(.bottom, 12)

            ForEach(SettingsTab.allCases) { tab in
                settingsSidebarButton(tab: tab)
            }

            Spacer()
        }
        .frame(width: 240)
        .background(
            DS.Colors.surface2
                .opacity(0.8)
        )
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedTab.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(selectedTab.subtitle)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .account:
            AccountTabView(
                accountManager: accountManager,
                profileManager: profileManager,
                pinManager: pinManager,
                onResetComplete: { closeSettingsPanel() }
            )
        case .api:
            APIProfilesTabView(profileManager: profileManager)
        case .model:
            ModelTabView(profileManager: profileManager)
        case .voice:
            VoiceSettingsTabView()
        case .agents:
            AgentModeTabView()
        case .general:
            GeneralTabView(pinManager: pinManager)
        }
    }

    @ViewBuilder
    private func settingsSidebarButton(tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent.opacity(0.16) : .clear)
            )
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case account
    case api
    case model
    case voice
    case agents
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .api: return "API"
        case .model: return "Model"
        case .voice: return "Voice"
        case .agents: return "Agents"
        case .general: return "General"
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.circle"
        case .api: return "key.horizontal"
        case .model: return "cpu"
        case .voice: return "waveform"
        case .agents: return "bubble.left.and.bubble.right"
        case .general: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .account:
            return "Manage your local identity and reset behavior."
        case .api:
            return "Configure API providers and connection profiles."
        case .model:
            return "Choose the active model for companion responses."
        case .voice:
            return "Adjust speech voice, pitch, rate, and volume."
        case .agents:
            return "Set agent limits, defaults, and agent-mode options."
        case .general:
            return "Open logs, app preferences, and maintenance actions."
        }
    }
}

// MARK: - Tab 1: Account

/// Displays the user's avatar, username, editable display name, and the destructive Reset Luma action.
@MainActor
private struct AccountTabView: View {

    @ObservedObject var accountManager: AccountManager
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var pinManager:     PINManager

    /// Called after a successful reset so the parent sheet can dismiss.
    var onResetComplete: () -> Void

    /// Draft of the display name being edited in the text field.
    @State private var editedDisplayName: String = ""

    /// Controls visibility of the "Reset Luma" confirmation alert.
    @State private var isShowingResetConfirmationAlert: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {

                if let account = accountManager.currentAccount {
                    accountContentView(account: account)
                } else {
                    noAccountPlaceholderView
                }
            }
            .padding(DS.Spacing.xl)
        }
        .onAppear {
            // Pre-populate the display name field with the current value.
            editedDisplayName = accountManager.currentAccount?.displayName ?? ""
        }
    }

    // MARK: Account Content

    private func accountContentView(account: LumaAccount) -> some View {
        VStack(spacing: DS.Spacing.xl) {

            // Avatar + identity block
            VStack(spacing: DS.Spacing.sm) {
                LumaAvatarView(initials: account.avatarInitials, size: 56)

                Text(account.username)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(account.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Divider()

            // Editable display name
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Display Name")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                TextField("Display name", text: $editedDisplayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(DS.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .stroke(DS.Colors.surface2, lineWidth: 1)
                    )
                    // Save when the user presses Return
                    .onSubmit {
                        saveDisplayNameIfChanged()
                    }
                    // Save when the field loses focus (blur equivalent in SwiftUI)
                    .onChange(of: editedDisplayName) { _ in
                        // We intentionally do NOT save on every keystroke;
                        // saving happens on submit/blur via onSubmit + focusLost.
                        // The onChange here is a no-op placeholder to make
                        // the "blur" pattern clear for future developers.
                    }
            }

            Divider()

            // Destructive: Reset Luma
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Danger Zone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                Button(role: .destructive) {
                    isShowingResetConfirmationAlert = true
                } label: {
                    Text("Reset Luma")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.destructive)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .alert(
                    "Reset Luma",
                    isPresented: $isShowingResetConfirmationAlert
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset", role: .destructive) {
                        performResetLuma()
                    }
                } message: {
                    Text("This will erase all data and restart onboarding. Are you sure?")
                }
            }
        }
    }

    // MARK: No-Account Placeholder

    private var noAccountPlaceholderView: some View {
        Text("No account. Complete onboarding to create one.")
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(DS.Spacing.xl)
    }

    // MARK: Actions

    private func saveDisplayNameIfChanged() {
        let trimmedName = editedDisplayName.trimmingCharacters(in: .whitespaces)
        // Only write to AccountManager if the value actually changed, to avoid
        // unnecessary Keychain/UserDefaults writes on every focus cycle.
        guard !trimmedName.isEmpty,
              trimmedName != accountManager.currentAccount?.displayName else { return }
        accountManager.updateDisplayName(trimmedName)
    }

    private func performResetLuma() {
        accountManager.deleteAccount()
        try? profileManager.deleteAllProfiles()
        // Wipe the entire vault (PIN, API keys)
        VaultManager.shared.deleteAll()
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        onResetComplete()
    }
}

// MARK: - Tab 2: API Profiles

/// Lists all stored API profiles with set-default, delete, add, and inline edit capabilities.
@MainActor
private struct APIProfilesTabView: View {

    @ObservedObject var profileManager: ProfileManager

    /// Whether the "Add Profile" inline form is expanded.
    @State private var isAddProfileFormExpanded: Bool = false

    /// The profile whose inline edit form is currently open (nil = none).
    @State private var profileIDBeingEdited: UUID? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.md) {

                // Existing profiles list
                ForEach(profileManager.profiles) { profile in
                    VStack(spacing: 0) {
                        ProfileRowView(
                            profile: profile,
                            totalProfileCount: profileManager.profiles.count,
                            isEditFormExpanded: profileIDBeingEdited == profile.id,
                            onSetDefault: {
                                profileManager.setDefaultProfile(withID: profile.id)
                            },
                            onDelete: {
                                try? profileManager.deleteProfile(withID: profile.id)
                                if profileIDBeingEdited == profile.id {
                                    profileIDBeingEdited = nil
                                }
                            },
                            onToggleEditForm: {
                                if profileIDBeingEdited == profile.id {
                                    profileIDBeingEdited = nil
                                } else {
                                    profileIDBeingEdited = profile.id
                                    // Collapse add form if it was open
                                    isAddProfileFormExpanded = false
                                }
                            },
                            onSaveEdit: { updatedProfile, apiKeyString in
                                profileManager.updateProfile(updatedProfile)
                                if !apiKeyString.isEmpty {
                                    try? profileManager.saveAPIKey(apiKeyString, forProfileID: updatedProfile.id)
                                }
                                profileIDBeingEdited = nil
                            }
                        )
                    }
                    .background(DS.Colors.surface1)
                    .cornerRadius(DS.CornerRadius.medium)
                }

                // "Add Profile" button and expandable form
                VStack(spacing: 0) {
                    Button {
                        isAddProfileFormExpanded.toggle()
                        // Collapse any open edit form when opening the add form
                        if isAddProfileFormExpanded {
                            profileIDBeingEdited = nil
                        }
                    } label: {
                        HStack {
                            Image(systemName: isAddProfileFormExpanded ? "minus.circle" : "plus.circle")
                            Text(isAddProfileFormExpanded ? "Cancel" : "Add Profile")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                        .padding(DS.Spacing.md)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isAddProfileFormExpanded {
                        ProfileFormView(
                            mode: .add,
                            existingProfile: nil,
                            existingAPIKey: nil,
                            onSave: { newProfile, apiKeyString in
                                profileManager.addProfile(newProfile)
                                if !apiKeyString.isEmpty {
                                    try? profileManager.saveAPIKey(apiKeyString, forProfileID: newProfile.id)
                                }
                                isAddProfileFormExpanded = false
                            },
                            onCancel: {
                                isAddProfileFormExpanded = false
                            }
                        )
                    }
                }
                .background(DS.Colors.surface1)
                .cornerRadius(DS.CornerRadius.medium)
            }
            .padding(DS.Spacing.xl)
        }
    }
}

// MARK: Profile Row

/// A single row in the API profiles list, with optional inline edit form.
@MainActor
private struct ProfileRowView: View {

    let profile: LumaAPIProfile
    let totalProfileCount: Int
    let isEditFormExpanded: Bool

    var onSetDefault:     () -> Void
    var onDelete:         () -> Void
    var onToggleEditForm: () -> Void
    var onSaveEdit:       (LumaAPIProfile, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Row header
            HStack(spacing: DS.Spacing.md) {

                // Checkmark for default profile
                Image(systemName: profile.isDefault ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(profile.isDefault ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)

                    // Provider badge
                    Text(profile.provider.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(DS.Colors.surface2)
                        .cornerRadius(DS.CornerRadius.small)
                }

                Spacer()

                // Action buttons
                HStack(spacing: DS.Spacing.sm) {

                    // Edit toggle
                    Button(isEditFormExpanded ? "Done" : "Edit") {
                        onToggleEditForm()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.textSecondary)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    // Set Default (disabled if already default)
                    Button("Set Default") {
                        onSetDefault()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(profile.isDefault ? DS.Colors.textTertiary : DS.Colors.accent)
                    .disabled(profile.isDefault)
                    .onHover { isHovering in
                        if isHovering && !profile.isDefault { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    // Delete (disabled if it's the only profile)
                    Button("Delete") {
                        onDelete()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(totalProfileCount <= 1 ? DS.Colors.textTertiary : DS.Colors.destructive)
                    .disabled(totalProfileCount <= 1)
                    .onHover { isHovering in
                        if isHovering && totalProfileCount > 1 { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
            .padding(DS.Spacing.lg)

            // Inline edit form (expands below the row header)
            if isEditFormExpanded {
                Divider()
                    .padding(.horizontal, DS.Spacing.md)

                ProfileFormView(
                    mode: .edit,
                    existingProfile: profile,
                    existingAPIKey: ProfileManager.shared.loadAPIKey(forProfileID: profile.id),
                    onSave: { updatedProfile, apiKeyString in
                        onSaveEdit(updatedProfile, apiKeyString)
                    },
                    onCancel: {
                        onToggleEditForm()
                    }
                )
            }
        }
    }
}

// MARK: Profile Form

/// Shared inline form used for both adding a new profile and editing an existing one.
@MainActor
private struct ProfileFormView: View {

    enum FormMode { case add, edit }

    let mode: FormMode
    let existingProfile: LumaAPIProfile?
    let existingAPIKey:  String?

    var onSave:   (LumaAPIProfile, String) -> Void
    var onCancel: () -> Void

    @State private var profileName:        String = ""
    @State private var selectedProvider:   LumaAPIProvider = .openRouter
    @State private var apiKeyInput:        String = ""
    @State private var isAPIKeyVisible:    Bool = false
    @State private var customBaseURL:      String = ""

    // Connection test state
    @State private var connectionTestStatus: ConnectionTestStatus = .idle

    enum ConnectionTestStatus {
        case idle
        case testing
        case success
        case failure(reason: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {

            // Name field
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Profile Name")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField("e.g. Work - OpenRouter", text: $profileName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(DS.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .stroke(DS.Colors.surface2, lineWidth: 1)
                    )
            }

            // Provider picker
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Provider")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(LumaAPIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Base URL (only shown for Custom provider)
            if selectedProvider == .custom {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Base URL")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                    TextField("https://your-endpoint.com/v1", text: $customBaseURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(DS.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                                .fill(DS.Colors.surface1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                                .stroke(DS.Colors.surface2, lineWidth: 1)
                        )
                }
            }

            // API key field with eye toggle
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("API Key")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)

                HStack {
                    if isAPIKeyVisible {
                        TextField("Paste API key here", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                    } else {
                        SecureField("Paste API key here", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                    }

                    Button {
                        isAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(DS.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .stroke(DS.Colors.surface2, lineWidth: 1)
                )
            }

            // Test Connection button + result
            HStack(spacing: DS.Spacing.sm) {
                Button("Test Connection") {
                    Task { await runConnectionTest() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.accent)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                // Inline connection test result
                switch connectionTestStatus {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView()
                        .scaleEffect(0.6)
                case .success:
                    Text("✓ Connected")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.success)
                case .failure(let reason):
                    Text("✗ Failed: \(reason)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.destructive)
                }
            }

            // Save / Cancel
            HStack(spacing: DS.Spacing.sm) {
                Button(mode == .add ? "Save Profile" : "Save Changes") {
                    saveProfile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(DS.Colors.accent)
                .cornerRadius(DS.CornerRadius.small)
                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
        }
        .padding(DS.Spacing.lg)
        .onAppear {
            populateFormFromExistingProfile()
        }
    }

    // MARK: Form Setup

    private func populateFormFromExistingProfile() {
        guard let profile = existingProfile else { return }
        profileName      = profile.name
        selectedProvider = profile.provider
        customBaseURL    = profile.baseURL
        apiKeyInput      = existingAPIKey ?? ""
    }

    // MARK: Actions

    private func saveProfile() {
        let trimmedName = profileName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let resolvedBaseURL = selectedProvider == .custom ? customBaseURL : ""

        // New profiles get a sensible default model so the first request doesn't
        // fail with "No model configured." Edited profiles keep their existing model.
        let resolvedModel: String
        if mode == .add {
            resolvedModel = defaultModelForProvider(selectedProvider)
        } else {
            resolvedModel = existingProfile?.selectedModel ?? ""
        }

        let profileToSave = LumaAPIProfile(
            id:            existingProfile?.id ?? UUID(),
            name:          trimmedName,
            provider:      selectedProvider,
            baseURL:       resolvedBaseURL,
            isDefault:     existingProfile?.isDefault ?? false,
            selectedModel: resolvedModel
        )

        onSave(profileToSave, apiKeyInput.trimmingCharacters(in: .whitespaces))
    }

    private func defaultModelForProvider(_ provider: LumaAPIProvider) -> String {
        switch provider {
        case .openRouter: return "google/gemini-2.5-flash:free"
        case .anthropic:  return "claude-sonnet-4-6"
        case .google:     return "gemini-2.0-flash"
        case .custom:     return ""
        }
    }

    /// GETs the provider's models list endpoint to verify the API key is valid.
    private func runConnectionTest() async {
        connectionTestStatus = .testing

        let trimmedAPIKey = apiKeyInput.trimmingCharacters(in: .whitespaces)
        guard !trimmedAPIKey.isEmpty else {
            connectionTestStatus = .failure(reason: "No API key entered")
            return
        }

        // Each provider exposes a GET /models endpoint for lightweight key validation
        let modelsEndpointURLString: String
        switch selectedProvider {
        case .openRouter:
            modelsEndpointURLString = "https://openrouter.ai/api/v1/models"
        case .anthropic:
            modelsEndpointURLString = "https://api.anthropic.com/v1/models"
        case .google:
            modelsEndpointURLString = "https://generativelanguage.googleapis.com/v1beta/models"
        case .custom:
            let trimmedBaseURL = customBaseURL.trimmingCharacters(in: .whitespaces)
            modelsEndpointURLString = trimmedBaseURL + "/models"
        }

        guard let requestURL = URL(string: modelsEndpointURLString) else {
            connectionTestStatus = .failure(reason: "Invalid URL")
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        // Each provider uses a different auth scheme for the models endpoint.
        // - Anthropic: x-api-key header (no Bearer prefix)
        // - Google AI: x-goog-api-key header (the /v1beta/models endpoint doesn't
        //   accept Authorization: Bearer — it needs the native Google key header)
        // - OpenRouter / Custom: Authorization: Bearer
        switch selectedProvider {
        case .anthropic:
            request.setValue(trimmedAPIKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            request.setValue(trimmedAPIKey, forHTTPHeaderField: "x-goog-api-key")
        default:
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                connectionTestStatus = .success
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                connectionTestStatus = .failure(reason: "HTTP \(statusCode)")
            }
        } catch {
            connectionTestStatus = .failure(reason: error.localizedDescription)
        }
    }
}

// MARK: - Tab 3: Model

/// Shows the active profile's selected model and allows editing it as plain text.
/// A full OpenRouter model picker will replace this text field in a future iteration.
@MainActor
private struct ModelTabView: View {

    @ObservedObject var profileManager: ProfileManager

    /// Draft model string being typed by the user.
    @State private var editedModelString: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {

                // Subtitle explaining the per-profile relationship
                Text("Model is selected per profile. Manage profiles in the API Profiles tab.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let activeProfile = profileManager.activeProfile {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {

                        // Active profile context
                        HStack(spacing: DS.Spacing.sm) {
                            Text("Active Profile:")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(activeProfile.name)
                                .font(.system(size: 13))
                                .foregroundColor(DS.Colors.textSecondary)
                        }

                        // Model string field
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("Model")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)

                            TextField("e.g. google/gemini-2.5-flash:free", text: $editedModelString)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundColor(DS.Colors.textPrimary)
                                .padding(DS.Spacing.sm)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                                        .fill(DS.Colors.surface1)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                                        .stroke(DS.Colors.surface2, lineWidth: 1)
                                )
                                // Save on Return
                                .onSubmit {
                                    saveModelStringToActiveProfile(activeProfile: activeProfile)
                                }

                            Text("Paste any OpenRouter or provider model ID here. A searchable picker is coming soon.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }

                        // Save button
                        Button("Save Model") {
                            saveModelStringToActiveProfile(activeProfile: activeProfile)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(DS.Colors.accent)
                        .cornerRadius(DS.CornerRadius.small)
                        .onHover { isHovering in
                            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                } else {
                    Text("No active profile. Add a profile in the API Profiles tab.")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .padding(DS.Spacing.xl)
        }
        .onAppear {
            editedModelString = profileManager.activeProfile?.selectedModel ?? ""
        }
    }

    private func saveModelStringToActiveProfile(activeProfile: LumaAPIProfile) {
        let trimmedModel = editedModelString.trimmingCharacters(in: .whitespaces)
        guard !trimmedModel.isEmpty else { return }
        // Build an updated copy of the active profile with the new model string
        var updatedProfile = activeProfile
        updatedProfile.selectedModel = trimmedModel
        profileManager.updateProfile(updatedProfile)
    }
}

// MARK: - Tab 4: General

/// Miscellaneous settings: launch-at-login, PIN management, and About.
@MainActor
private struct GeneralTabView: View {

    @ObservedObject var pinManager: PINManager

    // MARK: Launch at Login
    // Persisted in UserDefaults so it survives restarts.
    // The actual SMLoginItem enable/disable call happens in toggleLaunchAtLogin(enabled:).
    @AppStorage("launchAtLogin") private var launchAtLoginEnabled: Bool = false

    // MARK: PIN sheet state
    @State private var isShowingPINEntrySheet: Bool = false

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {

                launchAtLoginSection
                Divider()
                pinManagementSection
                Divider()
                logsSection
                Divider()
                memorySection
                Divider()
                historySection
                Divider()
                aboutSection
            }
            .padding(DS.Spacing.xl)
        }
        // PIN entry sheet (set or change)
        .sheet(isPresented: $isShowingPINEntrySheet) {
            PINEntryView(
                mode: .set,
                title: "Set a PIN",
                onSuccess: { isShowingPINEntrySheet = false },
                onCancel:  { isShowingPINEntrySheet = false }
            )
        }
    }

    // MARK: Launch at Login Section

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {

            Text("Launch at Login")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Toggle(isOn: $launchAtLoginEnabled) {
                Text("Start Luma automatically when you log in")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            .onChange(of: launchAtLoginEnabled) { newValue in
                toggleLaunchAtLogin(enabled: newValue)
            }
        }
    }

    // MARK: PIN Management Section

    private var pinManagementSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {

            Text("PIN")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            if pinManager.hasPIN {
                // PIN is set — show Change and Remove options
                HStack(spacing: DS.Spacing.md) {
                    Button("Change PIN") {
                        isShowingPINEntrySheet = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.accent)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Button("Remove PIN") {
                        try? pinManager.clearPIN()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.destructive)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }

            } else {
                // No PIN set — show Set PIN option
                Button("Set PIN") {
                    isShowingPINEntrySheet = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.accent)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }

    // MARK: Logs Section

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {

            Text("Logs")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("View real-time activity or copy the log file for debugging.")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Spacing.md) {
                Button {
                    LumaLogWindowManager.shared.showLogWindow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12))
                        Text("Open Log Window")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(DS.Colors.accent)
                    .cornerRadius(DS.CornerRadius.small)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button("Copy Logs") {
                    copyLogsToClipboard()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.accent)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }

    private func copyLogsToClipboard() {
        let logContents = LumaLogger.readCurrentLogFileContents() ?? "(no logs found)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logContents, forType: .string)
    }

    // MARK: Memory Section

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {

            Text("Memory")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("View and edit the global memory file Luma uses to remember preferences and facts between sessions.")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                LumaMemoryWindowManager.shared.showMemoryWindow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 12))
                    Text("Open Memory Editor")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(DS.Colors.accent)
                .cornerRadius(DS.CornerRadius.small)
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    // MARK: History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {

            Text("Conversation History")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Browse all conversations stored by agents and the companion. Supports search and bulk deletion.")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                LumaHistoryWindowManager.shared.showHistoryWindow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                    Text("Open Conversation History")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(DS.Colors.accent)
                .cornerRadius(DS.CornerRadius.small)
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    // MARK: About Section

    private var aboutSection: some View {
        // Centered About block with app version and copyright
        VStack(spacing: DS.Spacing.xs) {
            Text("Luma v1.0")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Text("© 2026 Omoju Oluwamayowa (Nox)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    // MARK: Actions

    /// Stub for SMLoginItem integration.
    /// Full implementation requires the com.apple.security.application-groups entitlement
    /// and an SMLoginItemHelper target — wiring those up is out of scope for this file.
    private func toggleLaunchAtLogin(enabled: Bool) {
        // TODO: Replace with SMLoginItemSetEnabled("com.nox.luma.LaunchHelper", enabled)
        // once the LoginItemHelper target and entitlements are configured.
        LumaLogger.log("[LaunchAtLogin] TODO: SMLoginItemSetEnabled called with enabled=\(enabled)")
    }
}

// MARK: - Tab 5: Voice Settings

/// Controls for Luma's text-to-speech voice: gender, pitch, rate, and volume.
/// All values persist to UserDefaults and are read by NativeTTSClient before each utterance.
@MainActor
private struct VoiceSettingsTabView: View {

    // Voice settings backed by UserDefaults via the same keys NativeTTSClient reads.
    @AppStorage(NativeTTSClient.voiceGenderKey)  private var voiceGender: String = "female"
    @AppStorage(NativeTTSClient.voicePitchKey)   private var voicePitch: Double  = 1.4
    @AppStorage(NativeTTSClient.voiceRateKey)    private var voiceRate: Double    = 0.52
    @AppStorage(NativeTTSClient.voiceVolumeKey)  private var voiceVolume: Double  = 1.0

    /// Whether a preview utterance is currently playing.
    @State private var isPreviewPlaying: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {

                Text("Configure how Luma sounds when speaking responses.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Gender toggle
                voiceGenderSection

                Divider()

                // Pitch slider
                voiceSliderSection(
                    title: "Pitch",
                    value: $voicePitch,
                    range: 0.5...2.0,
                    defaultValue: 1.4,
                    valueLabel: String(format: "%.2f", voicePitch),
                    description: "Higher values produce a higher-pitched voice."
                )

                Divider()

                // Rate / Tempo slider
                voiceSliderSection(
                    title: "Rate / Tempo",
                    value: $voiceRate,
                    range: 0.1...1.0,
                    defaultValue: 0.52,
                    valueLabel: String(format: "%.2f", voiceRate),
                    description: "Lower values speak more slowly."
                )

                Divider()

                // Volume slider
                voiceSliderSection(
                    title: "Volume",
                    value: $voiceVolume,
                    range: 0.0...1.0,
                    defaultValue: 1.0,
                    valueLabel: String(format: "%.0f%%", voiceVolume * 100),
                    description: "Speech output volume."
                )

                Divider()

                // Preview button
                previewVoiceSection
            }
            .padding(DS.Spacing.xl)
        }
    }

    // MARK: Gender Section

    private var voiceGenderSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Voice Gender")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            HStack(spacing: 0) {
                voiceGenderToggleButton(label: "Female", value: "female")
                voiceGenderToggleButton(label: "Male",   value: "male")
            }
            .background(DS.Colors.surface1)
            .cornerRadius(DS.CornerRadius.medium)
        }
    }

    private func voiceGenderToggleButton(label: String, value: String) -> some View {
        let isSelected = voiceGender == value
        return Button {
            voiceGender = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.sm)
                .background(isSelected ? DS.Colors.surface2 : Color.clear)
                .cornerRadius(DS.CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: Slider Section (Reusable)

    private func voiceSliderSection(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        valueLabel: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text(valueLabel)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .monospacedDigit()
            }

            Slider(value: value, in: range)
                .tint(DS.Colors.accent)

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: Preview Section

    private var previewVoiceSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Button {
                Task { await previewCurrentVoice() }
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: isPreviewPlaying ? "speaker.wave.3.fill" : "play.fill")
                        .font(.system(size: 12))
                    Text(isPreviewPlaying ? "Playing..." : "Preview Voice")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(DS.Colors.accent)
                .cornerRadius(DS.CornerRadius.small)
            }
            .buttonStyle(.plain)
            .disabled(isPreviewPlaying)
            .onHover { isHovering in
                if isHovering && !isPreviewPlaying { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    /// Speaks a short test string using the current voice settings.
    /// NativeTTSClient reads from UserDefaults each time, so settings changes
    /// made via the sliders above are picked up immediately.
    private func previewCurrentVoice() async {
        isPreviewPlaying = true
        do {
            try await NativeTTSClient.shared.speakText("Hi, I'm Luma. This is how I sound with your current settings.")
            await NativeTTSClient.shared.waitUntilFinished()
        } catch {
            // Preview is best-effort — swallow cancellation or other errors
        }
        isPreviewPlaying = false
    }
}

// MARK: - Tab 6: Agent Mode

/// Agent mode settings: maximum agent count stepper and per-agent model selection.
/// The max agent count is enforced by AgentSettingsManager. Per-agent model
/// selection is stored in AgentProfile structs persisted to UserDefaults.
@MainActor
private struct AgentModeTabView: View {

    @StateObject private var agentSettingsManager = AgentSettingsManager.shared
    @StateObject private var agentRuntimeManager = AgentRuntimeManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {

                Text("Configure agent mode behavior, runtime, and per-agent model assignments.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Agent mode toggle
                agentModeToggleSection

                Divider()

                // Runtime selection
                runtimeSection

                Divider()

                // Maximum Agents stepper
                maximumAgentsSection

                Divider()

                // Per-agent model configuration
                agentProfilesSection
            }
            .padding(DS.Spacing.xl)
        }
    }

    // MARK: Agent Mode Toggle

    private var agentModeToggleSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Toggle("Agent Mode", isOn: $agentSettingsManager.isAgentModeEnabled)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)

            Text("Enable the agent panel section and HUD dashboard for autonomous task execution.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Runtime Selection

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Agent Runtime")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            HStack(spacing: DS.Spacing.md) {
                Picker("Runtime", selection: runtimeOverrideBinding) {
                    Text("Auto-detect").tag("auto")
                    Text("Claude Code CLI").tag("claudeCode")
                    Text("Claude API").tag("claudeAPI")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                runtimeStatusIndicator
            }

            Text("Current: \(agentRuntimeManager.effectiveRuntimeType.rawValue)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            if let path = agentRuntimeManager.claudeCodePath {
                Text("CLI path: \(path)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var runtimeOverrideBinding: Binding<String> {
        Binding(
            get: {
                UserDefaults.standard.string(forKey: "luma.agentRuntime.override") ?? "auto"
            },
            set: { newValue in
                if newValue == "auto" {
                    UserDefaults.standard.removeObject(forKey: "luma.agentRuntime.override")
                } else {
                    agentRuntimeManager.setOverride(newValue)
                }
                agentRuntimeManager.detectRuntime()
            }
        )
    }

    @ViewBuilder
    private var runtimeStatusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(agentRuntimeManager.claudeCodePath != nil ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 7, height: 7)
            Text(agentRuntimeManager.claudeCodePath != nil ? "CLI detected" : "CLI not found")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: Maximum Agents

    private var maximumAgentsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Maximum Agents")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            HStack(spacing: DS.Spacing.md) {
                Stepper(
                    value: $agentSettingsManager.maxAgentCount,
                    in: 1...10,
                    step: 1
                ) {
                    Text("\(agentSettingsManager.maxAgentCount)")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .center)
                }

                Text("simultaneous agents allowed")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Text("When the limit is reached, the oldest idle agent is automatically dismissed.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Agent Profiles

    private var agentProfilesSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("Agent Profiles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button {
                    let newProfile = AgentProfile()
                    agentSettingsManager.addAgentProfile(newProfile)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                        Text("Add Agent")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            if agentSettingsManager.agentProfiles.isEmpty {
                Text("No agent profiles configured. Add one to assign a model.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, DS.Spacing.md)
            } else {
                ForEach(agentSettingsManager.agentProfiles) { profile in
                    AgentProfileRowView(
                        profile: profile,
                        onUpdateModel: { newModel in
                            var updated = profile
                            updated.model = newModel
                            agentSettingsManager.updateAgentProfile(updated)
                        },
                        onUpdateName: { newName in
                            var updated = profile
                            updated.name = newName
                            agentSettingsManager.updateAgentProfile(updated)
                        },
                        onDelete: {
                            agentSettingsManager.removeAgentProfile(withID: profile.id)
                        }
                    )
                }
            }

            Text("Default model: \(AgentModel.claudeSonnet.displayName). Each agent can use a different model for its API calls.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A single row in the agent profiles list showing name, model picker, and delete button.
@MainActor
private struct AgentProfileRowView: View {

    let profile: AgentProfile
    var onUpdateModel: (AgentModel) -> Void
    var onUpdateName:  (String) -> Void
    var onDelete:      () -> Void

    @State private var editedName: String = ""
    @State private var selectedModel: AgentModel = .claudeSonnet

    var body: some View {
        HStack(spacing: DS.Spacing.md) {

            // Editable agent name
            TextField("Agent name", text: $editedName)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: 120)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                        .fill(DS.Colors.surface1)
                )
                .onSubmit {
                    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onUpdateName(trimmed) }
                }

            // Model picker — grouped by provider
            Picker("Model", selection: $selectedModel) {
                ForEach(AgentModel.allCases) { model in
                    Text("\(model.displayName)")
                        .tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
            .onChange(of: selectedModel) { newModel in
                onUpdateModel(newModel)
            }

            Spacer()

            // Provider badge
            Text(selectedModel.providerName)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, 2)
                .background(DS.Colors.surface2)
                .cornerRadius(DS.CornerRadius.small)

            // Delete button
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.destructive)
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface1)
        .cornerRadius(DS.CornerRadius.medium)
        .onAppear {
            editedName = profile.name
            selectedModel = profile.model
        }
    }
}
