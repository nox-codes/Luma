//
//  FeedbackEngine.swift
//  leanring-buddy
//
//  Handles all user-facing communication during a walkthrough — positive
//  reinforcement when steps are completed, corrective prompts when the user
//  does the wrong thing, nudges when a step takes too long, and a completion
//  message when the full walkthrough is done. All feedback is delivered via TTS.
//

import AVFoundation
import Foundation

// MARK: - FeedbackEngine

@MainActor
final class FeedbackEngine {
    static let shared = FeedbackEngine()

    private let ttsClient = NativeTTSClient()

    /// How many nudges have been spoken for the current step.
    /// Reset to zero when a step is started or advanced.
    private var nudgeCount: Int = 0

    // Named constant — after this many nudges the message switches from repeating
    // the instruction to a gentler "take your time" prompt to avoid frustrating the user.
    private let maximumRepeatNudgesBeforeSwitchingToPatientMessage: Int = 3

    private init() {}

    // MARK: - Step Events

    /// Called when a step first becomes active — speaks the instruction so the
    /// user knows what to do without waiting for a timeout nudge.
    /// Prefixes with the step number so the user can track their progress.
    func announceStepStarted(instruction: String, humanReadableStepNumber: Int) async {
        let stepAnnouncementText = "Step \(humanReadableStepNumber). \(instruction)"
        try? await ttsClient.speakText(stepAnnouncementText)
    }

    /// Called when the user completes the current step correctly.
    /// Speaks a short positive confirmation. The next step's instruction is
    /// announced separately by `announceStepStarted` when `advanceToStep` fires.
    func announceStepCorrect() async {
        // "Good." is deliberately brief — patronising praise slows the walkthrough
        // and "Nice job!" gets old fast. The next instruction arrives right after
        // via `announceStepStarted`, which gives the user momentum to keep going.
        try? await ttsClient.speakText("Good.")
        await ttsClient.waitUntilFinished()
    }

    /// Called when the user performed an action that doesn't match the current step.
    /// Speaks a gentle correction followed by a re-statement of the current instruction.
    func announceStepIncorrect(reason: String, currentInstruction: String) async {
        let correctionMessage = "That's not quite right. \(currentInstruction)"
        try? await ttsClient.speakText(correctionMessage)
    }

    /// Called when the step timer fires — the user hasn't completed the step yet.
    /// For the first few nudges, repeats the instruction. After that, switches to
    /// a patient "take your time" message so the user doesn't feel harassed.
    func announceStepTimeout(currentInstruction: String, stepNumber: Int, nudgesSoFar: Int) async {
        if nudgesSoFar < maximumRepeatNudgesBeforeSwitchingToPatientMessage {
            // Re-state which step we're on and repeat the instruction
            let nudgeMessage = "Still on step \(stepNumber + 1). \(currentInstruction)"
            try? await ttsClient.speakText(nudgeMessage)
        } else {
            // After enough nudges, switch to a patient message.
            // This prevents the nudge from becoming annoying when the user is
            // intentionally taking their time or has stepped away.
            try? await ttsClient.speakText("Take your time, I'm here when you're ready.")
        }

        // Increment the nudge count so the next timeout fires the correct variant
        nudgeCount += 1
    }

    /// Called when the user completes all steps in the walkthrough.
    func announceWalkthroughComplete(goal: String) async {
        let completionMessage = "You did it! \(goal) complete."
        try? await ttsClient.speakText(completionMessage)
    }

    // MARK: - Nudge Counter

    /// Resets the nudge counter. Called by WalkthroughEngine when advancing to a new step.
    func resetNudgeCount() {
        nudgeCount = 0
    }

    /// The current nudge count for the active step.
    /// Exposed so WalkthroughEngine can pass `nudgesSoFar` to `announceStepTimeout`.
    var currentNudgeCount: Int {
        nudgeCount
    }
}
