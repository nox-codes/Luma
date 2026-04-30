//
//  NudgeEngine.swift
//  leanring-buddy
//
//  All walkthrough correction and nudge messages go through here.
//  Zero Claude API calls — every message is spoken directly via NativeTTSClient.
//  Claude is only called by WalkthroughEngine on a periodic verification schedule
//  (every claudeVerificationInterval steps) or when the user is stuck after three nudges.
//

import Foundation

// MARK: - NudgeSituation

/// The situation that triggered a walkthrough nudge. Each case maps to a specific
/// offline message template in NudgeEngine so no API call is needed for corrections.
enum NudgeSituation {
    /// The expected UI element could not be located on screen.
    case elementNotFound
    /// The user is in the wrong application. Associated value is the expected app name.
    case wrongApp(String)
    /// The step timer fired — the user hasn't acted yet.
    case timeout
    /// The user did something close but not quite right — generic retry prompt.
    case retry
    /// The user completed this step successfully — advance to next.
    case stepComplete
    /// The user has been nudged three times without progress — escalate to Claude.
    case stuckAfterThreeNudges
}

// MARK: - NudgeEngine

/// Offline nudge message factory and fire-and-forget TTS speaker.
/// All messages are resolved locally — callers do not need async/await.
struct NudgeEngine {

    // MARK: - Message Templates

    /// Returns the spoken message for a given nudge situation.
    /// All strings are deliberately short — they will be spoken aloud mid-task.
    static func message(for situation: NudgeSituation) -> String {
        switch situation {
        case .elementNotFound:
            return "That doesn't seem to be quite right. Let me re-point you."
        case .wrongApp(let expectedAppName):
            return "Looks like we need to be in \(expectedAppName). Let's switch over."
        case .timeout:
            return "Take your time — still here whenever you're ready."
        case .retry:
            return "Almost! Give that one more try."
        case .stepComplete:
            return "Got it. Moving to the next step."
        case .stuckAfterThreeNudges:
            // This situation DOES trigger a Claude call in WalkthroughEngine —
            // the message is spoken first, then the engine escalates to AI.
            return "Let me check what's going on and find a better path."
        }
    }

    // MARK: - Speak

    /// Speaks the nudge message for `situation` via NativeTTSClient.
    /// Fire-and-forget — no return value, no await needed.
    static func speak(_ situation: NudgeSituation) {
        let nudgeText = message(for: situation)
        NativeTTSClient.shared.speak(nudgeText)
    }
}
