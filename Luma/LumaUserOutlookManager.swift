//
//  LumaUserOutlookManager.swift
//  Luma
//
//  Manages the user's behavioral Outlook — an AI-generated markdown profile that Luma
//  silently updates after every interaction. The profile accumulates expertise signals,
//  personality traits, work patterns, and interests so Luma personalizes responses with
//  increasing accuracy over time.
//
//  Storage: ~/Library/Application Support/Luma/.profile/outlook.md
//  The .profile subdirectory uses a dot prefix to stay hidden from casual Finder browsing.
//  Application Support is never cleared by macOS cache or maintenance routines.
//
//  Coined: "User Profile" / "Outlook"
//

import AppKit
import Foundation

/// Singleton that manages the user's AI-generated behavioral profile ("Outlook").
/// Reads the profile for system prompt injection on every request and silently
/// updates it in the background after each interaction completes.
/// Thread-safe via NSLock — mirrors the same pattern as LumaMemoryManager.
final class LumaUserOutlookManager: @unchecked Sendable {

    static let shared = LumaUserOutlookManager()

    // MARK: - File Paths

    /// Hidden subdirectory inside Luma's Application Support folder.
    private let profileDirectoryURL: URL

    /// The outlook markdown file. Dot-prefixed parent keeps it out of casual searches.
    private let outlookFileURL: URL

    // MARK: - Threading

    /// NSLock guards all file I/O so background update tasks never race with reads.
    private let fileLock = NSLock()
    private let fileManager = FileManager.default

    // MARK: - Init

    private init() {
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        profileDirectoryURL = appSupportURL
            .appendingPathComponent("Luma/.profile", isDirectory: true)
        outlookFileURL = profileDirectoryURL.appendingPathComponent("outlook.md")
        createProfileDirectoryIfNeeded()
    }

    // MARK: - Public: Load / Prompt Injection

    /// Loads the current outlook profile content. Returns empty string if no profile exists yet.
    func loadOutlook() -> String {
        fileLock.lock()
        defer { fileLock.unlock() }
        return (try? String(contentsOf: outlookFileURL, encoding: .utf8)) ?? ""
    }

    /// Builds a formatted system prompt block containing the user's outlook profile.
    /// Returns nil if no profile has been built yet (no interactions observed).
    func outlookSystemPromptSection() -> String? {
        let profileContent = loadOutlook()
        guard !profileContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return """
        ## User Profile & Behavioral Outlook
        The following profile was built from your observed interactions with this user. \
        Use it to personalize tone, match expertise level, and anticipate needs:

        \(profileContent)

        ---
        """
    }

    // MARK: - Public: Observation (Fire-and-Forget)

    /// Observes a completed interaction and updates the profile in the background.
    /// Must be called on the main actor so ProfileManager (which is @MainActor) can be accessed
    /// safely. Captures credentials up-front, then hands off to a background Task — never blocks.
    @MainActor
    func observeInteractionAsync(userInput: String, aiResponse: String) {
        // Resolve API credentials synchronously on the main actor before the background task.
        guard let activeProfile = ProfileManager.shared.activeProfile,
              let apiKey = ProfileManager.shared.loadAPIKey(forProfileID: activeProfile.id),
              !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        let capturedProfile = activeProfile
        let capturedKey = apiKey

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.performOutlookUpdatePass(
                userInput: userInput,
                aiResponse: aiResponse,
                profile: capturedProfile,
                apiKey: capturedKey
            )
        }
    }

    // MARK: - Private: Profile Update

    /// Sends the interaction to the AI using a cheap model and saves the updated profile.
    private func performOutlookUpdatePass(
        userInput: String,
        aiResponse: String,
        profile: LumaAPIProfile,
        apiKey: String
    ) async {
        let existingOutlook = loadOutlook()
        let existingProfileForPrompt = existingOutlook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No profile entries yet — this is the first observation."
            : existingOutlook

        let systemPrompt = """
        You are a behavioral analyst building a persistent markdown profile of a user \
        based on their interactions with an AI assistant called Luma. Your observations \
        shape how Luma personalizes future responses.

        Analyze the new interaction and return a COMPLETE updated markdown profile. Capture:
        - Expertise areas and knowledge depth (specific domains, tools, languages, frameworks)
        - Work style, habits, and decision-making patterns
        - Communication style and vocabulary preferences
        - Goals, ongoing projects, recurring themes, and interests
        - Personality traits (curiosity, directness, patience, creativity, attention to detail)
        - Behavioral patterns worth remembering across sessions

        Rules:
        - Return ONLY the raw markdown — no preamble, no meta-commentary, no explanations
        - Include ALL existing entries, updated or unchanged — never truncate the profile
        - Add new insights; only remove entries clearly contradicted by newer evidence
        - Use concise bullet points under clear section headers (##)
        - Omit anything too generic to be meaningfully useful
        - If the interaction reveals nothing new, return the profile completely unchanged
        """

        let userMessage = """
        Existing profile:
        \(existingProfileForPrompt)

        New interaction to analyze:
        User: \(userInput)
        Luma: \(String(aiResponse.prefix(700)))

        Return the complete updated profile in markdown.
        """

        do {
            let updatedProfile = try await callOutlookUpdateAPI(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                profile: profile,
                apiKey: apiKey
            )
            let trimmed = updatedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            fileLock.lock()
            try? trimmed.write(to: outlookFileURL, atomically: true, encoding: .utf8)
            fileLock.unlock()
        } catch {
            LumaLogger.log("[Outlook] Profile update failed: \(error.localizedDescription)")
        }
    }

    /// Calls the user's AI provider with a text-only prompt using a cheap/fast model.
    /// Matches the same provider-aware request format as LumaIntentClassifier.
    private func callOutlookUpdateAPI(
        systemPrompt: String,
        userMessage: String,
        profile: LumaAPIProfile,
        apiKey: String
    ) async throws -> String {
        // Use the cheapest available model per provider to keep observation overhead minimal.
        let cheapModelID: String
        switch profile.provider {
        case .anthropic:  cheapModelID = "claude-haiku-4-5-20251001"
        case .openRouter: cheapModelID = "google/gemini-2.0-flash-lite:free"
        case .google:     cheapModelID = "gemini-2.0-flash-lite"
        case .custom:     cheapModelID = profile.selectedModel
        }

        var requestHeaders: [String: String] = ["Content-Type": "application/json"]
        let endpointURL: URL
        let requestBodyObject: [String: Any]

        if profile.provider == .anthropic {
            endpointURL = URL(string: "\(profile.effectiveBaseURL)/messages")!
            requestHeaders["x-api-key"] = apiKey
            requestHeaders["anthropic-version"] = "2023-06-01"
            requestBodyObject = [
                "model": cheapModelID,
                "max_tokens": 1200,
                "system": systemPrompt,
                "messages": [["role": "user", "content": userMessage]]
            ]
        } else {
            let baseEndpointURL = profile.provider == .google
                ? "https://generativelanguage.googleapis.com/v1beta/openai"
                : profile.effectiveBaseURL
            endpointURL = URL(string: "\(baseEndpointURL)/chat/completions")!
            requestHeaders["Authorization"] = "Bearer \(apiKey)"
            requestBodyObject = [
                "model": cheapModelID,
                "max_tokens": 1200,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        requestHeaders.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBodyObject)

        let (responseData, httpResponse) = try await URLSession.shared.data(for: urlRequest)

        guard let httpURLResponse = httpResponse as? HTTPURLResponse,
              (200...299).contains(httpURLResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]

        // Parse the response text from Anthropic's content array or OpenAI-compatible choices.
        if profile.provider == .anthropic {
            if let contentBlocks = responseJSON?["content"] as? [[String: Any]],
               let firstBlock = contentBlocks.first,
               let extractedText = firstBlock["text"] as? String {
                return extractedText
            }
        } else {
            if let choicesArray = responseJSON?["choices"] as? [[String: Any]],
               let firstChoice = choicesArray.first,
               let messageObject = firstChoice["message"] as? [String: Any],
               let extractedText = messageObject["content"] as? String {
                return extractedText
            }
        }

        throw URLError(.cannotParseResponse)
    }

    // MARK: - Public: Reset

    /// Clears the outlook profile file. Called when the user resets their profile from the UI.
    /// The empty file is preserved so the directory structure stays intact.
    func resetOutlook() {
        fileLock.lock()
        defer { fileLock.unlock() }
        try? "".write(to: outlookFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private Helpers

    private func createProfileDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: profileDirectoryURL.path) else { return }
        try? fileManager.createDirectory(
            at: profileDirectoryURL,
            withIntermediateDirectories: true
        )
    }
}
