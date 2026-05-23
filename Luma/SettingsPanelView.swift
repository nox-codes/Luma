//
//  SettingsPanelView.swift
//  leanring-buddy
//
//  4-tab settings panel presented as a sheet from the menu bar panel.
//  Tabs: Account, API Profiles, Model, General.
//

import AVFoundation
import SwiftUI

// MARK: - SettingsPanelView

@MainActor
struct SettingsPanelView: View {

    @Environment(\.dismiss) private var dismiss

    // Triggers re-render whenever the user changes the accent theme, so the Done
    // button and sidebar selected states immediately reflect the new accent color.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

    // Observe singletons so changes in each tab update the UI immediately.
    @StateObject private var accountManager = AccountManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var pinManager    = PINManager.shared

    /// Which tab is currently selected.
    @State private var selectedTab: SettingsTab = .account

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            VStack(spacing: 0) {
                // Top bar — Done button sits tight to the right edge with DS accent styling.
                HStack {
                    Spacer()
                    Button("Done") {
                        closeSettingsPanel()
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Rectangle().fill(DS.Colors.accent))
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.leading, 20)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                // WindowDragHandle sits behind all controls so clicking the empty
                // area of the top bar drags the window, while the Done button and
                // any other interactive views above it still fire normally.
                .background(WindowDragHandle())

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        settingsHeader
                        selectedTabContent
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Colors.background)
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(DS.Colors.background)
        .focusEffectDisabled()
    }

    private func closeSettingsPanel() {
        LumaSettingsWindowManager.shared.hideSettingsWindow()
        dismiss()
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Title row — no close button (Done is in the top-right of the content area)
            Text("Luma Settings")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 11)
                .padding(.top, 20)
                .padding(.bottom, 10)

            ForEach(SettingsTab.allCases) { tab in
                settingsSidebarButton(tab: tab)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 220)
        .background(DS.Colors.surface2)
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
                pinManager: pinManager
            )
        case .api:
            APIProfilesTabView(profileManager: profileManager)
        case .model:
            ModelTabView(profileManager: profileManager)
        case .voice:
            VoiceSettingsTabView()
        case .agents:
            AgentModeTabView()
        case .customization:
            CustomizationTabView()
        case .general:
            GeneralTabView(
                pinManager: pinManager,
                accountManager: accountManager,
                profileManager: profileManager,
                onResetComplete: { closeSettingsPanel() }
            )
        }
    }

    @ViewBuilder
    private func settingsSidebarButton(tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textSecondary)
                    .frame(width: 20)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                Rectangle()
                    .fill(isSelected ? DS.Colors.accentSubtle : .clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(DS.Colors.accent)
                        .frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
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
    case customization
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account:       return "Account"
        case .api:           return "API"
        case .model:         return "Model"
        case .voice:         return "Voice"
        case .agents:        return "Agents"
        case .customization: return "Customization"
        case .general:       return "General"
        }
    }

    var icon: String {
        switch self {
        case .account:       return "person.circle"
        case .api:           return "key.horizontal"
        case .model:         return "cpu"
        case .voice:         return "waveform"
        case .agents:        return "bubble.left.and.bubble.right"
        case .customization: return "paintpalette"
        case .general:       return "gearshape"
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
        case .customization:
            return "Choose accent color and agent bubble appearance."
        case .general:
            return "Open logs, app preferences, and maintenance actions."
        }
    }
}

// MARK: - Tab 1: Account

/// Displays the user's avatar, username, and editable display name.
/// Display name edits auto-save after a 0.8s debounce — no Save button required.
/// Danger Zone (Reset Luma) has been moved to the General tab.
@MainActor
private struct AccountTabView: View {

    @ObservedObject var accountManager: AccountManager
    @ObservedObject var profileManager: ProfileManager
    @ObservedObject var pinManager:     PINManager

    // Forces re-render when the accent theme changes so DS.Colors.accent is fresh.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

    /// Draft of the display name being edited in the text field.
    @State private var editedDisplayName: String = ""

    /// Cancellable debounce task — cancelled and recreated on every keystroke so
    /// the actual save only fires 0.8s after the user stops typing.
    @State private var displayNameSaveDebounceTask: Task<Void, Never>? = nil

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

            // Avatar — initials update live while the user types in the display name field
            VStack(spacing: DS.Spacing.sm) {
                LumaAvatarView(initials: liveAvatarInitials(forAccount: account), size: 56)

                Text(account.username)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                // Display name preview also updates live as the user types
                Text(editedDisplayName.isEmpty ? account.displayName : editedDisplayName)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Divider()

            // Editable display name — auto-saves with a 0.8s debounce after each keystroke.
            // No Save button is needed; the hint text confirms auto-save behavior.
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Display Name")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                TextField("Display name", text: $editedDisplayName)
                    .textFieldStyle(.plain)
                    .tint(DS.Colors.accent)
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
                    .onChange(of: editedDisplayName) { _ in
                        scheduleDebouncedDisplayNameSave()
                    }

                Text("Changes save automatically.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
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

    /// Computes avatar initials from the current `editedDisplayName` draft so the
    /// avatar updates live while the user types — before the save is committed.
    private func liveAvatarInitials(forAccount account: LumaAccount) -> String {
        let source = editedDisplayName.count >= 2 ? editedDisplayName : account.username
        return String(source.prefix(2)).uppercased()
    }

    /// Cancels any pending debounce task and schedules a new one that fires after 0.8s.
    /// The save only happens when the user pauses or stops typing.
    private func scheduleDebouncedDisplayNameSave() {
        displayNameSaveDebounceTask?.cancel()
        displayNameSaveDebounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: 800_000_000) // 0.8 seconds
                saveDisplayNameIfChanged()
            } catch {
                // Task was cancelled (user kept typing) — no action needed
            }
        }
    }

    private func saveDisplayNameIfChanged() {
        let trimmedName = editedDisplayName.trimmingCharacters(in: .whitespaces)
        // Only write to AccountManager if the value actually changed, to avoid
        // unnecessary UserDefaults writes on every debounce cycle.
        guard !trimmedName.isEmpty,
              trimmedName != accountManager.currentAccount?.displayName else { return }
        accountManager.updateDisplayName(trimmedName)
    }
}

// MARK: - Tab 2: API Profiles

/// Lists all stored API profiles with set-default, delete, add, and inline edit capabilities.
@MainActor
private struct APIProfilesTabView: View {

    @ObservedObject var profileManager: ProfileManager

    // Triggers re-render so the "Add Profile" button accent color updates immediately.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

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

    // Triggers re-render so the checkmark and "Set Default" button reflect the new accent immediately.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

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

    // Triggers re-render so "Test Connection" and "Save Profile" accent colors update immediately.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

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
                    .tint(DS.Colors.accent)
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
                        .tint(DS.Colors.accent)
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
                            .tint(DS.Colors.accent)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                    } else {
                        SecureField("Paste API key here", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                            .tint(DS.Colors.accent)
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
                    Label("Connected", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.success)
                case .failure(let reason):
                    Label("Failed: \(reason)", systemImage: "xmark")
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

/// Searchable model picker with provider sections (Anthropic, OpenRouter, Google AI).
/// Tapping a row auto-saves the selection to the active profile immediately.
/// A free-text field at the bottom accepts any custom model identifier as a fallback.
@MainActor
private struct ModelTabView: View {

    @ObservedObject var profileManager: ProfileManager

    // Triggers re-render so the selected model row highlight and "Save" button update immediately.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

    /// Text typed in the search field — filters all three provider sections simultaneously.
    @State private var searchText: String = ""

    /// Draft for the free-text custom model fallback field.
    @State private var customModelText: String = ""

    // MARK: Static model lists grouped by provider

    private let anthropicModels: [(id: String, label: String)] = [
        ("claude-opus-4-6",            "Claude Opus 4.6"),
        ("claude-sonnet-4-6",          "Claude Sonnet 4.6"),
        ("claude-haiku-4-5-20251001",  "Claude Haiku 4.5"),
        ("claude-opus-4",              "Claude Opus 4"),
        ("claude-sonnet-4",            "Claude Sonnet 4"),
        ("claude-3-5-sonnet-20241022", "Claude 3.5 Sonnet"),
    ]

    private let openRouterModels: [(id: String, label: String)] = [
        ("google/gemini-2.5-flash:free",           "Gemini 2.5 Flash (free)"),
        ("google/gemini-2.5-pro:free",             "Gemini 2.5 Pro (free)"),
        ("meta-llama/llama-3.3-70b-instruct:free", "Llama 3.3 70B (free)"),
        ("deepseek/deepseek-chat:free",            "DeepSeek Chat (free)"),
        ("deepseek/deepseek-r1:free",              "DeepSeek R1 (free)"),
        ("microsoft/phi-4:free",                   "Phi-4 (free)"),
        ("qwen/qwen-2.5-72b-instruct:free",        "Qwen 2.5 72B (free)"),
        ("openai/gpt-4o",                          "GPT-4o"),
        ("openai/gpt-4o-mini",                     "GPT-4o Mini"),
        ("anthropic/claude-sonnet-4-6",            "Claude Sonnet 4.6 (via OR)"),
    ]

    private let googleModels: [(id: String, label: String)] = [
        ("gemini-2.0-flash", "Gemini 2.0 Flash"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash"),
        ("gemini-2.5-pro",   "Gemini 2.5 Pro"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {

                Text("Model is selected per profile. Manage profiles in the API Profiles tab.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let activeProfile = profileManager.activeProfile {

                    // Active profile context
                    HStack(spacing: DS.Spacing.sm) {
                        Text("Active Profile:")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(activeProfile.name)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textSecondary)
                    }

                    // Search field — filters all provider sections
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                        TextField("Search models…", text: $searchText)
                            .textFieldStyle(.plain)
                            .tint(DS.Colors.accent)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                            .stroke(DS.Colors.surface2, lineWidth: 1)
                    )

                    // Provider sections — each hides itself when the filtered list is empty
                    modelSection(title: "Anthropic", models: filteredModels(anthropicModels), activeProfile: activeProfile)
                    modelSection(title: "OpenRouter", models: filteredModels(openRouterModels), activeProfile: activeProfile)
                    modelSection(title: "Google AI", models: filteredModels(googleModels), activeProfile: activeProfile)

                    Divider()

                    // Free-text fallback for any custom or unlisted model identifier
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Custom Model ID")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)

                        HStack(spacing: 8) {
                            TextField("e.g. google/gemini-2.5-flash:free", text: $customModelText)
                                .textFieldStyle(.plain)
                                .tint(DS.Colors.accent)
                                .font(.system(size: 13))
                                .foregroundColor(DS.Colors.textPrimary)
                                .onSubmit { saveCustomModel(activeProfile: activeProfile) }

                            Button("Save") { saveCustomModel(activeProfile: activeProfile) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.accentText)
                                .disabled(customModelText.trimmingCharacters(in: .whitespaces).isEmpty)
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

                        Text("Paste any OpenRouter or provider model ID. Tap a row above to select a preset.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
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
            customModelText = profileManager.activeProfile?.selectedModel ?? ""
        }
    }

    // MARK: Helpers

    /// Filters a model list by the current search text. Returns all when search is empty.
    private func filteredModels(_ models: [(id: String, label: String)]) -> [(id: String, label: String)] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return models }
        let lowercased = query.lowercased()
        return models.filter {
            $0.id.lowercased().contains(lowercased) || $0.label.lowercased().contains(lowercased)
        }
    }

    /// Renders a provider section with its header label and model rows.
    /// Hidden entirely when the filtered list for that provider is empty.
    @ViewBuilder
    private func modelSection(title: String, models: [(id: String, label: String)], activeProfile: LumaAPIProfile) -> some View {
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.bottom, 2)

                VStack(spacing: 2) {
                    ForEach(models, id: \.id) { model in
                        modelRowView(model: model, activeProfile: activeProfile)
                    }
                }
                .background(DS.Colors.surface1)
                .cornerRadius(DS.CornerRadius.medium)
            }
        }
    }

    /// A single tappable model row. Saves immediately on tap.
    /// Selected row shows accentSubtle background and a checkmark in accentText.
    private func modelRowView(model: (id: String, label: String), activeProfile: LumaAPIProfile) -> some View {
        let isSelected = activeProfile.selectedModel == model.id
        return Button {
            saveModel(modelID: model.id, activeProfile: activeProfile)
        } label: {
            HStack(spacing: DS.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(model.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(isSelected ? DS.Colors.accentSubtle : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func saveModel(modelID: String, activeProfile: LumaAPIProfile) {
        var updatedProfile = activeProfile
        updatedProfile.selectedModel = modelID
        profileManager.updateProfile(updatedProfile)
    }

    private func saveCustomModel(activeProfile: LumaAPIProfile) {
        let trimmedModel = customModelText.trimmingCharacters(in: .whitespaces)
        guard !trimmedModel.isEmpty else { return }
        saveModel(modelID: trimmedModel, activeProfile: activeProfile)
    }
}

// MARK: - Tab: Customization

/// Accent theme picker + agent bubble style and behavior sliders.
/// Consolidated from GeneralTabView (accent) and AgentModeTabView (bubble).
@MainActor
private struct CustomizationTabView: View {

    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeRaw: String = LumaAccentTheme.white.rawValue
    @StateObject private var floatingStyleManager = FloatingInputStyleManager.shared
    @AppStorage(LumaAutoHideInterval.enabledUserDefaultsKey) private var isAutoHideEnabled: Bool = true
    @AppStorage(LumaAutoHideInterval.intervalUserDefaultsKey) private var autoHideIntervalSeconds: Double = 300

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                accentThemeSection
                Divider()
                autoHideSection
                Divider()
                floatingInputStyleSection
                Divider()
                BubbleAppearanceSectionView()
            }
            .padding(DS.Spacing.xl)
        }
    }

    // MARK: Accent Theme

    private var accentThemeSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Accent Theme")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            HStack(spacing: 16) {
                ForEach(LumaAccentTheme.allCases) { theme in
                    accentThemeCircle(theme: theme)
                }
                Spacer()
            }

            Text("Updates the cursor color, agent bubble glow, and accent highlights throughout the app.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accentThemeCircle(theme: LumaAccentTheme) -> some View {
        let isSelected = accentThemeRaw == theme.rawValue
        return Button {
            accentThemeRaw = theme.rawValue
        } label: {
            VStack(spacing: 7) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Rectangle()
                            .stroke(isSelected ? theme.accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 2 : 1)
                            .padding(isSelected ? -4 : 0)
                    )
                    .animation(.easeInOut(duration: 0.15), value: isSelected)

                Text(theme.title.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: Auto-Hide

    /// Auto-hide section: toggle + interval picker shown only when auto-hide is on.
    /// Choosing "Never" keeps Luma's cursor visible until the user explicitly hides it.
    private var autoHideSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Section header
            Text("Auto-Hide")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Automatically hide Luma's cursor overlay after a period of inactivity.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            // Enabled toggle row
            HStack(spacing: 12) {
                Toggle("", isOn: $isAutoHideEnabled)
                    .toggleStyle(RetroToggleStyle())
                    .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-hide when idle")
                        .font(.system(size: 13, weight: isAutoHideEnabled ? .semibold : .regular))
                        .foregroundColor(isAutoHideEnabled ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    Text("Shake your mouse at any time to wake Luma back up.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Rectangle().fill(isAutoHideEnabled ? DS.Colors.accentSubtle : DS.Colors.surface2))
            .overlay(Rectangle().stroke(isAutoHideEnabled ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: 1))
            .animation(.easeInOut(duration: 0.15), value: isAutoHideEnabled)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            // Duration picker — only shown when auto-hide is enabled
            if isAutoHideEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HIDE AFTER")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 6)

                    VStack(spacing: 0) {
                        ForEach(LumaAutoHideInterval.allCases) { interval in
                            autoHideIntervalRow(interval: interval)
                        }
                    }
                    .overlay(Rectangle().stroke(DS.Colors.borderSubtle, lineWidth: 1))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.15), value: isAutoHideEnabled)
            }
        }
        // Fire the custom notification immediately when either setting changes so
        // CompanionManager updates the idle timer without relying on the unreliable
        // UserDefaults.didChangeNotification path.
        .onChange(of: isAutoHideEnabled) { _ in
            NotificationCenter.default.post(name: LumaAutoHideInterval.settingsChangedNotification, object: nil)
        }
        .onChange(of: autoHideIntervalSeconds) { _ in
            NotificationCenter.default.post(name: LumaAutoHideInterval.settingsChangedNotification, object: nil)
        }
    }

    private func autoHideIntervalRow(interval: LumaAutoHideInterval) -> some View {
        let isSelected = autoHideIntervalSeconds == interval.rawValue
        return Button {
            autoHideIntervalSeconds = interval.rawValue
        } label: {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Rectangle()
                        .stroke(isSelected ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                    if isSelected {
                        Rectangle()
                            .fill(DS.Colors.accent)
                            .frame(width: 6, height: 6)
                    }
                }

                Text(interval.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DS.Colors.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Rectangle().fill(isSelected ? DS.Colors.accentSubtle : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }

    // MARK: Floating Input Style

    private var floatingInputStyleSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Quick Input Style")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("The pill that appears when you double-tap \u{2318} or ^. Changes apply immediately.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            VStack(spacing: 10) {
                ForEach(FloatingInputStyle.allCases, id: \.rawValue) { style in
                    floatingStyleRow(style: style)
                }
            }
        }
    }

    private func floatingStyleRow(style: FloatingInputStyle) -> some View {
        let isSelected = floatingStyleManager.currentStyle == style
        return Button {
            floatingStyleManager.currentStyle = style
        } label: {
            HStack(spacing: 14) {
                // Selection indicator square
                ZStack {
                    Rectangle()
                        .stroke(isSelected ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if isSelected {
                        Rectangle()
                            .fill(DS.Colors.accent)
                            .frame(width: 8, height: 8)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    Text(style.description)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                // Mini preview
                miniPreview(for: style)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Rectangle()
                    .fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2)
            )
            .overlay(
                Rectangle()
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    @ViewBuilder
    private func miniPreview(for style: FloatingInputStyle) -> some View {
        let accent = Color(hex: "#ffffff")
        switch style {
        case .pillClean:
            Rectangle()
                .fill(Color(hex: "#141614"))
                .overlay(Rectangle().stroke(accent.opacity(0.3), lineWidth: 1))
                .frame(width: 80, height: 20)
                .overlay(
                    HStack(spacing: 4) {
                        Rectangle().fill(accent).frame(width: 5, height: 5)
                        Rectangle().fill(Color(hex: "#555D58")).frame(width: 36, height: 2)
                    }
                    .padding(.leading, 8)
                    , alignment: .leading
                )

        case .widerCard:
            Rectangle()
                .fill(Color(hex: "#0E1210"))
                .overlay(
                    Rectangle()
                        .stroke(accent.opacity(0.4), lineWidth: 1)
                )
                .frame(width: 88, height: 22)
                .overlay(
                    HStack(spacing: 4) {
                        Text("\u{2318}\u{2318}")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "#555D58"))
                        Rectangle().fill(Color(hex: "#2E322E")).frame(width: 0.5, height: 10)
                        Rectangle().fill(Color(hex: "#555D58")).frame(width: 28, height: 2)
                    }
                    .padding(.horizontal, 6)
                )

        case .cursorAnchored:
            VStack(spacing: 0) {
                HStack {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 16, height: 4)
                    Spacer()
                }
                .padding(.leading, 8)
                Rectangle()
                    .fill(Color(hex: "#141614"))
                    .overlay(
                        Rectangle()
                            .stroke(accent.opacity(0.35), lineWidth: 0.5)
                    )
                    .frame(width: 88, height: 18)
            }
            .frame(width: 88)
        }
    }
}

// MARK: - Tab 4: General

/// Miscellaneous settings: launch-at-login, PIN management, and About.
@MainActor
private struct GeneralTabView: View {

    @ObservedObject var pinManager:     PINManager
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var profileManager: ProfileManager

    /// Called after a successful Reset Luma so the settings window can close.
    var onResetComplete: () -> Void

    // MARK: Launch at Login
    // Persisted in UserDefaults so it survives restarts.
    // The actual SMLoginItem enable/disable call happens in toggleLaunchAtLogin(enabled:).
    @AppStorage("launchAtLogin") private var launchAtLoginEnabled: Bool = false

    // MARK: Accent Theme
    // Stored in the same UserDefaults key that LumaAccentTheme.current reads from.
    // Changing this live-updates all DS.Colors.accent / DS.Colors.accentText / overlayCursorBlue calls.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeRaw: String = LumaAccentTheme.white.rawValue

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
                userOutlookSection
                Divider()
                historySection
                Divider()
                aboutSection
                Divider()
                dangerZoneSection
            }
            .padding(DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.xl)
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

    // MARK: Accent Theme Section

    /// Four colored circles. Tapping one updates `accentThemeRaw` in UserDefaults,
    /// which `LumaAccentTheme.current` reads at render time — so DS.Colors.accent,
    /// DS.Colors.accentText, and DS.Colors.overlayCursorBlue all update live.
    private var accentThemeSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Accent Theme")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            HStack(spacing: 16) {
                ForEach(LumaAccentTheme.allCases) { theme in
                    accentThemeCircle(theme: theme)
                }
                Spacer()
            }

            Text("Affects the cursor color, bubble border, and accent highlights throughout the app.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accentThemeCircle(theme: LumaAccentTheme) -> some View {
        let isSelected = accentThemeRaw == theme.rawValue
        return Button {
            accentThemeRaw = theme.rawValue
        } label: {
            VStack(spacing: 7) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Rectangle()
                            .stroke(isSelected ? theme.accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 2 : 1)
                            .padding(isSelected ? -4 : 0)
                    )
                    .animation(.easeInOut(duration: 0.15), value: isSelected)

                Text(theme.title.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
            .toggleStyle(RetroToggleStyle())
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

    // MARK: User Outlook Section

    /// Shows the "User Profile" (Outlook) section — a read-only AI-generated behavioral
    /// profile Luma builds silently from every interaction. Stored in a hidden directory
    /// in Application Support so it persists across launches without cluttering the UI.
    private var userOutlookSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {

            Text("User Profile")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Luma observes every interaction and quietly builds a behavioral profile — your expertise, interests, and work patterns. This profile personalizes every response and is never shared.")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                LumaOutlookWindowManager.shared.showOutlookWindow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 12))
                    Text("View Profile")
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
            Text("Luma v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
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

    // MARK: Danger Zone Section

    /// Destructive Reset Luma action — moved here from the Account tab so account
    /// management stays clean and the destructive action lives with other maintenance tools.
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Danger Zone")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.destructive)

            Button(role: .destructive) {
                showResetLumaConfirmationAlert()
            } label: {
                Text("Reset Luma")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.destructive)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .stroke(DS.Colors.destructive, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Text("Clears all settings, profiles, and conversation history. Cannot be undone.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shows a native NSAlert confirmation before executing the destructive reset.
    /// NSAlert is used (rather than SwiftUI .alert) so the dialog is modal and
    /// the destructive button gets native red styling from the system.
    private func showResetLumaConfirmationAlert() {
        let alert = NSAlert()
        alert.messageText = "Reset Luma?"
        alert.informativeText = "This will clear all settings, profiles, and conversation history."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performResetLuma()
        }
    }

    private func performResetLuma() {
        accountManager.deleteAccount()
        try? profileManager.deleteAllProfiles()
        VaultManager.shared.deleteAll()
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        onResetComplete()
    }
}

// MARK: - Tab 5: Voice Settings

/// Controls for Luma's text-to-speech voice: gender, pitch, rate, and volume.
/// All values persist to UserDefaults and are read by NativeTTSClient before each utterance.
@MainActor
private struct VoiceSettingsTabView: View {

    // Forces re-render when the accent theme changes so DS.Colors.accent is fresh.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

    // Voice settings backed by UserDefaults via the same keys NativeTTSClient reads.
    @AppStorage(NativeTTSClient.voiceGenderKey)      private var voiceGender: String  = "female"
    @AppStorage(NativeTTSClient.voiceNameKey)        private var voiceName: String    = ""
    @AppStorage(NativeTTSClient.voicePitchKey)       private var voicePitch: Double   = 1.4
    @AppStorage(NativeTTSClient.voiceRateKey)        private var voiceRate: Double     = 0.52
    @AppStorage(NativeTTSClient.voiceVolumeKey)      private var voiceVolume: Double   = 1.0
    @AppStorage(NativeTTSClient.shouldSanitizeKey)    private var shouldSanitize: Bool     = true
    // Default true — preserves existing behavior (Luma always speaks responses aloud).
    @AppStorage(NativeTTSClient.autoReadResponsesKey) private var autoReadResponses: Bool = true

    /// Whether a preview utterance is currently playing.
    @State private var isPreviewPlaying: Bool = false

    /// English-language voices installed on this Mac, sorted by display name.
    /// Discovered dynamically from AVSpeechSynthesisVoice so new voices appear automatically.
    private var availableEnglishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }

    /// Display name of the currently active voice, looked up from the stored identifier.
    /// Falls back to gender-based name when no specific voice is selected.
    private var activeVoiceDisplayName: String {
        guard !voiceName.isEmpty else {
            return voiceGender == "male" ? "Aaron" : "Samantha"
        }
        return AVSpeechSynthesisVoice(identifier: voiceName)?.name ?? voiceName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {

                // Voice picker — named system voices as capsule buttons
                voicePickerSection

                Divider()

                // Pitch slider
                voiceSliderSection(
                    title: "Pitch",
                    value: $voicePitch,
                    range: 0.5...2.0,
                    sliderColor: DS.Colors.success,
                    leftLabel: "Low",
                    rightLabel: "High",
                    valueLabel: String(format: "%.2f", voicePitch)
                )

                Divider()

                // Rate / Tempo slider
                voiceSliderSection(
                    title: "Speaking Rate",
                    value: $voiceRate,
                    range: 0.1...1.0,
                    sliderColor: DS.Colors.accent,
                    leftLabel: "Slow",
                    rightLabel: "Fast",
                    valueLabel: String(format: "%.0f%%", (voiceRate / 1.0) * 100)
                )

                Divider()

                // Volume slider
                voiceSliderSection(
                    title: "Volume",
                    value: $voiceVolume,
                    range: 0.0...1.0,
                    sliderColor: DS.Colors.warning,
                    leftLabel: "Quiet",
                    rightLabel: "Loud",
                    valueLabel: String(format: "%.0f%%", voiceVolume * 100)
                )

                Divider()

                // Behaviour toggles
                behaviourSection

                Divider()

                // Preview
                previewVoiceSection
            }
            .padding(DS.Spacing.xl)
        }
    }

    // MARK: Voice Picker Section

    private var voicePickerSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Voice")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            // Horizontally wrapping capsule chips — one per installed English voice.
            // Tapping a chip selects the voice and immediately plays an audio preview.
            FlowLayout(spacing: 8) {
                ForEach(availableEnglishVoices, id: \.identifier) { voice in
                    voiceChip(voice: voice)
                }
            }

            Text("Shows all English voices installed on this Mac. Install more in System Settings → Accessibility → Spoken Content.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A single voice chip. Tapping selects the voice by saving its AVSpeechSynthesisVoice
    /// identifier to UserDefaults and immediately triggers a short audio preview so the
    /// user can hear the voice before committing.
    private func voiceChip(voice: AVSpeechSynthesisVoice) -> some View {
        let isSelected = voiceName == voice.identifier
        return Button {
            // Store the full identifier so NativeTTSClient can call AVSpeechSynthesisVoice(identifier:) directly
            voiceName = voice.identifier
            Task { await previewCurrentVoice() }
        } label: {
            Text(voice.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Rectangle()
                        .fill(isSelected ? DS.Colors.accent : DS.Colors.surface2)
                )
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 1)
                )
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
        sliderColor: Color,
        leftLabel: String,
        rightLabel: String,
        valueLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                HStack(spacing: 10) {
                    Text(leftLabel)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text(valueLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(sliderColor)
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)

                    Text(rightLabel)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            RetroSlider(value: value, range: range, tintColor: sliderColor)
        }
    }

    // MARK: Behaviour Section

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Behaviour")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            // Strip coordinate strings toggle
            settingsToggleRow(
                label: "Strip coordinate strings",
                description: "Removes coordinate patterns like 'point 400, 200' from spoken text",
                isOn: $shouldSanitize
            )

            // Auto-read responses toggle
            settingsToggleRow(
                label: "Auto-read responses",
                description: "Speaks every AI response aloud automatically",
                isOn: $autoReadResponses
            )
        }
    }

    /// A labelled toggle row used in the Behaviour section.
    private func settingsToggleRow(label: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .toggleStyle(RetroToggleStyle())
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    // MARK: Preview Section

    private var previewVoiceSection: some View {
        HStack(spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(activeVoiceDisplayName) · Rate \(String(format: "%.0f", (voiceRate / 1.0) * 100))% · Pitch \(String(format: "%.2f", voicePitch))")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Click play to hear a sample")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await previewCurrentVoice() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isPreviewPlaying ? "speaker.wave.3.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(isPreviewPlaying ? "Playing…" : "Play")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DS.Colors.surface2)
                .overlay(
                    Rectangle()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isPreviewPlaying)
            .onHover { isHovering in
                if isHovering && !isPreviewPlaying { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .cornerRadius(DS.CornerRadius.medium)
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

// MARK: - FlowLayout
//
// A simple wrapping horizontal layout used for the voice picker chips.
// Chips wrap to a new row when they overflow the available width.

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if currentRowWidth + subviewSize.width > containerWidth && currentRowWidth > 0 {
                totalHeight += currentRowHeight + spacing
                currentRowWidth = subviewSize.width + spacing
                currentRowHeight = subviewSize.height
            } else {
                currentRowWidth += subviewSize.width + spacing
                currentRowHeight = max(currentRowHeight, subviewSize.height)
            }
        }
        totalHeight += currentRowHeight
        return CGSize(width: containerWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var originX = bounds.minX
        var originY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if originX + subviewSize.width > bounds.maxX && originX > bounds.minX {
                originX = bounds.minX
                originY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: originX, y: originY), proposal: ProposedViewSize(subviewSize))
            originX += subviewSize.width + spacing
            rowHeight = max(rowHeight, subviewSize.height)
        }
    }
}

// MARK: - Tab 6: Agent Mode

/// Agent mode settings: maximum agent count stepper and per-agent model selection.
/// The max agent count is enforced by AgentSettingsManager. Per-agent model
/// selection is stored in AgentProfile structs persisted to UserDefaults.
@MainActor
private struct AgentModeTabView: View {

    // Forces re-render when the accent theme changes so DS.Colors.accent is fresh.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

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
                .toggleStyle(RetroToggleStyle())

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

    // Forces re-render when the accent theme changes so DS.Colors.accent is fresh.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.white.rawValue

    @State private var editedName: String = ""
    @State private var selectedModel: AgentModel = .claudeSonnet

    var body: some View {
        HStack(spacing: DS.Spacing.md) {

            // Editable agent name
            TextField("Agent name", text: $editedName)
                .textFieldStyle(.plain)
                .tint(DS.Colors.accent)
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
