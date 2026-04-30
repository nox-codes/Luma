//
//  PostOnboardingTutorialManager.swift
//  leanring-buddy
//
//  Drives a 5-step walkthrough that runs once after the user completes
//  onboarding. Each step shows a tooltip in the companion panel, highlights
//  a relevant UI element with a pulse ring, and auto-advances after 4 s.
//  Completion is stored in UserDefaults so the tutorial never shows twice.
//

import Combine
import Foundation

struct PostOnboardingTutorialStep {
    let text: String
    /// Which panel element to visually highlight (nil = none).
    let highlightTarget: PostOnboardingTutorialHighlight?
}

enum PostOnboardingTutorialHighlight {
    case companionBubble   // Step 1 — the floating cursor companion
    case menuBarIcon       // Step 2 — the status bar lightbulb
    case shortcutHint      // Step 3 & 4 — the "Hold Ctrl+Option" row in the panel
}

@MainActor
final class PostOnboardingTutorialManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var currentStepIndex: Int = 0

    private static let userDefaultsKey = "hasCompletedTutorial"

    let steps: [PostOnboardingTutorialStep] = [
        PostOnboardingTutorialStep(
            text: "This is your companion bubble — it follows your cursor everywhere.",
            highlightTarget: .companionBubble
        ),
        PostOnboardingTutorialStep(
            text: "Click the lightbulb in your menu bar to open Luma anytime.",
            highlightTarget: .menuBarIcon
        ),
        PostOnboardingTutorialStep(
            text: "Hold Control+Option to start talking to Luma.",
            highlightTarget: .shortcutHint
        ),
        PostOnboardingTutorialStep(
            text: "Ask anything — Luma sees your screen and can point at what it means.",
            highlightTarget: .shortcutHint
        ),
        PostOnboardingTutorialStep(
            text: "That's it. Luma will guide you step by step. Go learn something.",
            highlightTarget: nil
        ),
    ]

    var currentStep: PostOnboardingTutorialStep? {
        guard isActive && steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var isLastStep: Bool {
        currentStepIndex >= steps.count - 1
    }

    var hasCompletedTutorial: Bool {
        UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
    }

    private var autoAdvanceTask: Task<Void, Never>?

    /// Starts the tutorial if it hasn't been completed before.
    func startIfNeeded() {
        guard !hasCompletedTutorial else { return }
        currentStepIndex = 0
        isActive = true
        scheduleAutoAdvance()
        LumaLogger.log("📖 Tutorial: started — step 1 of \(steps.count)")
    }

    /// Advances to the next step, or completes the tutorial if on the last step.
    func advance() {
        autoAdvanceTask?.cancel()
        guard isActive else { return }

        if isLastStep {
            complete()
        } else {
            currentStepIndex += 1
            LumaLogger.log("📖 Tutorial: advanced to step \(currentStepIndex + 1)")
            scheduleAutoAdvance()
        }
    }

    /// Marks the tutorial complete and hides it.
    func complete() {
        autoAdvanceTask?.cancel()
        isActive = false
        UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
        LumaLogger.log("📖 Tutorial: completed")
    }

    private func scheduleAutoAdvance() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            advance()
        }
    }
}
