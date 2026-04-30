//
//  NativeTTSClient.swift
//  leanring-buddy
//
//  Speaks text using macOS native AVSpeechSynthesizer. Fully local —
//  no external API calls. Replaces the previous ElevenLabs integration.
//

import AVFoundation
import Foundation

@MainActor
final class NativeTTSClient: NSObject, AVSpeechSynthesizerDelegate {

    /// Shared singleton used by WalkthroughEngine and other callers that need
    /// fire-and-forget speech without owning their own synthesizer instance.
    static let shared = NativeTTSClient()

    private let synthesizer = AVSpeechSynthesizer()

    /// Continuation used to bridge the delegate callback into async/await.
    /// Set when speech begins, resolved when it finishes or is cancelled.
    private var speechFinishedContinuation: CheckedContinuation<Void, Never>?

    /// Tracks whether the synthesizer is actively speaking.
    private(set) var isPlaying: Bool = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Fire-and-forget speech. Wraps the async `speakText` in a Task so callers
    /// that don't need to await completion can use this without async/await boilerplate.
    /// Used by WalkthroughEngine for step instructions and nudge messages.
    func speak(_ text: String) {
        Task { try? await self.speakText(text) }
    }

    /// Strips coordinate tokens and related technical patterns from `text` before speaking.
    /// Prevents the synthesizer from reading out things like "point 400 comma 200" or
    /// "x colon 150 y colon 300" that Claude occasionally includes in its responses.
    private func sanitizeSpeech(_ text: String) -> String {
        var cleaned = text

        // Each pattern targets a different coordinate format Claude might embed in a response.
        let coordinatePatterns: [String] = [
            #"point\s*\(\s*\d+\s*,\s*\d+\s*\)"#,        // point(400, 200)
            #"\(\s*\d{2,4}\s*,\s*\d{2,4}\s*\)"#,          // (400, 200)
            #"\[\s*\d{2,4}\s*,\s*\d{2,4}\s*\]"#,          // [400, 200]
            #"\{\s*x\s*:\s*\d+\s*,\s*y\s*:\s*\d+\s*\}"#,  // {x: 400, y: 200}
            #"at coordinates \d+,?\s*\d+"#,                 // at coordinates 400, 200
            #"position \d+,?\s*\d+"#,                       // position 400, 200
            #"\bx:\s*\d+,?\s*y:\s*\d+"#,                   // x: 400, y: 200
        ]

        for pattern in coordinatePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let fullRange = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: fullRange, withTemplate: "")
            }
        }

        return cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - UserDefaults Keys for Voice Settings

    /// UserDefaults key for voice gender preference ("male" or "female").
    static let voiceGenderKey   = "luma.voice.gender"
    /// UserDefaults key for pitch multiplier (Float, 0.5–2.0).
    static let voicePitchKey    = "luma.voice.pitch"
    /// UserDefaults key for speech rate (Float, 0.1–1.0).
    static let voiceRateKey     = "luma.voice.rate"
    /// UserDefaults key for speech volume (Float, 0.0–1.0).
    static let voiceVolumeKey   = "luma.voice.volume"

    /// Speaks `text` using a natural macOS voice. Returns once playback starts.
    /// The caller can poll `isPlaying` to wait for completion.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()

        stopPlayback()

        let utterance = AVSpeechUtterance(string: sanitizeSpeech(text))

        // Read voice settings from UserDefaults, falling back to original defaults
        let defaults = UserDefaults.standard

        let storedRate = defaults.object(forKey: Self.voiceRateKey) as? Float
        utterance.rate = storedRate ?? 0.52

        let storedPitch = defaults.object(forKey: Self.voicePitchKey) as? Float
        utterance.pitchMultiplier = storedPitch ?? 1.4

        let storedVolume = defaults.object(forKey: Self.voiceVolumeKey) as? Float
        utterance.volume = storedVolume ?? 1.0

        // Determine voice based on gender setting
        let gender = defaults.string(forKey: Self.voiceGenderKey) ?? "female"
        utterance.voice = resolveVoiceForGender(gender)

        isPlaying = true
        synthesizer.speak(utterance)
        LumaLogger.log("Native TTS: speaking \(text.count) characters (rate=\(utterance.rate), pitch=\(utterance.pitchMultiplier), vol=\(utterance.volume), gender=\(gender))")
    }

    /// Resolves the best available AVSpeechSynthesisVoice for the given gender string.
    /// Female prefers Zoe → Samantha → system default.
    /// Male prefers Aaron (enhanced) → Aaron (compact) → system default male voice.
    private func resolveVoiceForGender(_ gender: String) -> AVSpeechSynthesisVoice? {
        if gender == "male" {
            if let aaronEnhanced = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.en-US.Aaron") {
                return aaronEnhanced
            } else if let aaronCompact = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Aaron-compact") {
                return aaronCompact
            }
            // Fall through to find any male en-US voice
            let maleVoices = AVSpeechSynthesisVoice.speechVoices().filter {
                $0.language.hasPrefix("en") && $0.gender == .male
            }
            if let firstMale = maleVoices.first { return firstMale }
            return AVSpeechSynthesisVoice(language: "en-US")
        } else {
            // Female (default) — original preference order
            if let zoeEnhanced = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.en-US.Zoe") {
                return zoeEnhanced
            } else if let zoeCompact = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Zoe-compact") {
                return zoeCompact
            } else if let samantha = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Samantha-compact") {
                return samantha
            }
            return AVSpeechSynthesisVoice(language: "en-US")
        }
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        // Resolve any pending continuation so callers aren't left hanging
        speechFinishedContinuation?.resume()
        speechFinishedContinuation = nil
    }

    /// Waits until the current utterance finishes. Returns immediately if nothing is playing.
    func waitUntilFinished() async {
        guard isPlaying else { return }
        await withCheckedContinuation { continuation in
            self.speechFinishedContinuation = continuation
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.speechFinishedContinuation?.resume()
            self.speechFinishedContinuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.speechFinishedContinuation?.resume()
            self.speechFinishedContinuation = nil
        }
    }
}
