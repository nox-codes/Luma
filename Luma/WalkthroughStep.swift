//
//  WalkthroughStep.swift
//  leanring-buddy
//
//  Data models for the WalkthroughEngine system. Defines a single step in
//  a guided walkthrough, the JSON wrapper the AI returns, and the state machine
//  that drives the overall flow.
//

import Foundation

// MARK: - WalkthroughStep

/// A single step in a guided walkthrough.
/// Each step tells the user exactly what to do (instruction), names the precise
/// UI element to find (elementName), and carries optional hints for where to look.
struct WalkthroughStep: Codable, Identifiable {
    let id: UUID
    let index: Int              // 0-based step number
    let instruction: String     // What to say to the user (spoken aloud + shown in UI)
    let elementName: String     // Exact AX element title to find, point at, and watch for
    let elementRole: String?    // AXButton, AXMenuItem, etc. — optional scoring hint
    let appBundleID: String?    // Which app this step happens in (nil = frontmost app)
    let isMenuBar: Bool         // true when the element lives in the macOS menu bar hierarchy
    let timeoutSeconds: Int     // Seconds before the first nudge fires (default 15)

    init(
        index: Int,
        instruction: String,
        elementName: String,
        elementRole: String? = nil,
        appBundleID: String? = nil,
        isMenuBar: Bool = false,
        timeoutSeconds: Int = 15
    ) {
        self.id = UUID()
        self.index = index
        self.instruction = instruction
        self.elementName = elementName
        self.elementRole = elementRole
        self.appBundleID = appBundleID
        self.isMenuBar = isMenuBar
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case instruction
        case elementName
        case elementRole
        case appBundleID
        case isMenuBar
        case timeoutSeconds
    }

    /// Custom decoder so the AI-generated JSON (which has no UUID) still decodes correctly.
    /// UUID is always generated fresh — it is never included in the AI response.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id             = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.index          = try container.decode(Int.self, forKey: .index)
        self.instruction    = try container.decode(String.self, forKey: .instruction)
        self.elementName    = try container.decode(String.self, forKey: .elementName)
        self.elementRole    = try? container.decode(String.self, forKey: .elementRole)
        self.appBundleID    = try? container.decode(String.self, forKey: .appBundleID)
        self.isMenuBar      = (try? container.decode(Bool.self, forKey: .isMenuBar)) ?? false
        self.timeoutSeconds = (try? container.decode(Int.self, forKey: .timeoutSeconds)) ?? 15
    }
}

// MARK: - WalkthroughPlan

/// The full JSON object the AI returns from TaskPlanner.
/// totalSteps is computed from steps.count so a missing or differently-keyed
/// "totalSteps" field in the AI response never causes a decode failure.
struct WalkthroughPlan: Codable {
    let steps: [WalkthroughStep]
    var totalSteps: Int { steps.count }

    private enum CodingKeys: String, CodingKey { case steps }
}

// MARK: - WalkthroughState

/// The state machine that drives the WalkthroughEngine.
/// Each case represents a distinct phase of the walkthrough lifecycle.
enum WalkthroughState {
    /// Not in walkthrough mode — engine is idle.
    case idle

    /// AI is generating the step plan.
    case planning

    /// AI returned steps; showing them to the user to confirm before starting.
    case confirming([WalkthroughStep])

    /// Walkthrough is in progress. currentIndex is the zero-based active step.
    case executing(steps: [WalkthroughStep], currentIndex: Int)

    /// All steps completed successfully.
    case complete

    /// Walkthrough paused (reserved for future use).
    case paused
}
