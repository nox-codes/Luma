//
//  LumaFlowModels.swift
//  leanring-buddy
//
//  Data models for LumaFlow: step lifecycle, planning response, per-step action
//  request, observation results, recovery decisions, and shared execution context.
//

import Foundation

// MARK: - Step State

/// Lifecycle state of a single step in a LumaFlow plan.
enum LumaFlowStepState {
    case pending
    case inProgress
    case completed
    case failed(String)
    case skipped
}

// MARK: - Flow Step

/// One discrete step in a LumaFlow rough plan, as returned by the upfront planning call.
struct LumaFlowStep: Identifiable {
    let id: UUID
    /// Short action label (e.g. "Open Safari", "Search for ticket", "Click Buy Now").
    let label: String
    var state: LumaFlowStepState
    /// How many execution attempts have been made for this step.
    var attemptCount: Int
    /// Description of what happened when this step last executed (fed back into next replan).
    var resultObservation: String?

    init(label: String) {
        self.id = UUID()
        self.label = label
        self.state = .pending
        self.attemptCount = 0
    }
}

// MARK: - Planning Response

/// JSON structure returned by the upfront planning API call.
struct LumaFlowPlan: Codable {
    let steps: [String]
    let estimatedDuration: String
    let requiresApps: [String]
    let warnings: [String]
}

// MARK: - Dynamic Action Request

/// JSON structure returned by the per-step dynamic replan call.
/// Claude specifies exactly what action to take for the current step.
struct LumaFlowActionRequest: Codable {
    /// The action to perform:
    /// click | clickAt | type | scroll | shortcut | selectText | drag | wait | ask | abort | done
    /// "done" signals that the current step's goal is fully accomplished — no payload needed.
    /// "clickAt" clicks a screen position using fractional coordinates (0.0–1.0) relative to the
    /// primary screen bounds — use this when no AX element can be found via label/role search.
    let actionType: String
    /// Label or text of the AX element to target (button title, link text, field placeholder, etc.)
    let targetElementLabel: String?
    /// AX role of the target element (button, textField, link, menuItem, etc.)
    let targetElementRole: String?
    /// Keyboard shortcut string, e.g. "Cmd+C", "Cmd+Shift+T"
    let shortcut: String?
    /// Text to type into the focused/target field
    let typeText: String?
    /// How many seconds to wait (for the "wait" action type)
    let waitSeconds: Double?
    /// Question to surface to the user in the bubble (for "ask" type)
    let askQuestion: String?
    /// Human-readable reason for aborting the entire task (for "abort" type)
    let abortReason: String?
    /// What Claude expects to observe on screen after this action — used by the observer
    let observation: String?
    /// Short label for what immediately follows (context for the next replan call)
    let nextMicroStep: String?
    /// Horizontal fraction of the screen to click (0.0 = left edge, 1.0 = right edge).
    /// Only used when actionType is "clickAt".
    let xFraction: Double?
    /// Vertical fraction of the screen to click (0.0 = top edge, 1.0 = bottom edge).
    /// Only used when actionType is "clickAt".
    let yFraction: Double?
}

// MARK: - Observation Result

/// Result of the 10-second polling observation loop after an action.
enum LumaFlowObservationResult {
    /// The expected AX element or text was found — step succeeded.
    case success
    /// 10-second deadline expired without confirming the expected state.
    case timeout
}

// MARK: - Recovery Action

/// Decision returned by the recovery chain when a step fails or times out.
enum LumaFlowRecoveryAction {
    /// Retry the same step (permitted up to 2× per step).
    case retry
    /// Ask Claude for an alternative approach to this step.
    case adapt
    /// Surface a question to the user in the agent bubble.
    case ask(String)
    /// Stop the task and report what was completed.
    case abort(String)
}

// MARK: - Step Execution Result

/// Internal result from one attempt at executing a step (including observation).
enum LumaFlowStepResult {
    case completed(String)       // success with observation description
    case failed(String)          // non-fatal failure — engine continues to next step
    case aborted(String)         // fatal — engine stops the entire task
    case waitingForUser(String)  // surfaced question to user in bubble
}

// MARK: - Execution Context

/// Shared mutable state carried through one LumaFlow session.
/// The engine updates this after every action so replan calls have fresh context.
@MainActor
final class LumaFlowContext {
    let sessionId: UUID
    /// The original user goal as stated.
    let goal: String
    /// Rough plan steps populated after the upfront planning call.
    var roughPlan: [LumaFlowStep]
    /// Labels of steps that completed successfully — included in every replan prompt.
    var completedStepLabels: [String]
    /// Whether the user or engine requested cancellation.
    var cancelRequested: Bool
    /// App names from the planning call ("Safari", "Finder", etc.)
    var requiresApps: [String]
    var estimatedDuration: String
    /// Warnings from the planning call, e.g. "will send email"
    var warnings: [String]
    /// Last human-readable observation from the executor or observer — fed into replan.
    var lastObservation: String
    /// Whether the most recent screenshot diff detected a screen change.
    var didLastScreenChange: Bool
    /// Sampled pixel hash of the previous screenshot for diff comparison.
    var previousScreenshotHash: Int?

    init(goal: String) {
        self.sessionId = UUID()
        self.goal = goal
        self.roughPlan = []
        self.completedStepLabels = []
        self.cancelRequested = false
        self.requiresApps = []
        self.estimatedDuration = ""
        self.warnings = []
        self.lastObservation = "Task just started"
        self.didLastScreenChange = false
    }
}
