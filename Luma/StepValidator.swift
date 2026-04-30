//
//  StepValidator.swift
//  leanring-buddy
//
//  Validates whether an accessibility event matches what the current
//  walkthrough step expected. Returns a typed result so WalkthroughEngine
//  can decide whether to advance, give corrective feedback, or ignore.
//

import Foundation

// MARK: - StepValidator

/// Validates a single AccessibilityEvent against the current WalkthroughStep.
/// Called by WalkthroughEngine every time AccessibilityWatcher fires an event.
@MainActor
final class StepValidator {

    enum ValidationResult {
        /// The event matches what the step expected — advance to the next step.
        case correct

        /// The wrong thing happened in the right app. Provide corrective feedback.
        case incorrect(reason: String)

        /// The event has nothing to do with this step. Silently ignore it.
        case unrelated
    }

    // MARK: - Validation Entry Point

    /// Compares an accessibility event against the expected state for a walkthrough step.
    /// The logic works in layers: app → action type → element name, from broadest to most specific.
    func validate(event: AccessibilityEvent, step: WalkthroughStep) -> ValidationResult {

        // --- App bundle ID check ---
        // If the step specifies an app, the event must come from that app.
        // Events from other apps are always unrelated — the user may be switching
        // windows or doing something else entirely.
        if let expectedBundleID = step.appBundleID {
            guard event.appBundleID == expectedBundleID else {
                return .unrelated
            }
        }

        // --- Steps with no specific element requirement ---
        // elementName is a non-optional String; empty string means "any action in this app counts".
        let stepHasNoSpecificElement = step.elementName.isEmpty

        if stepHasNoSpecificElement {
            // Any event from the correct app (or any app if no bundleID constraint) counts as correct.
            return .correct
        }

        // --- Element name check ---
        // Check whether the event's element title or role contains the step's elementName.
        // Case-insensitive substring matching handles minor label variations across macOS versions.
        let titleMatches = event.elementTitle?.localizedCaseInsensitiveContains(step.elementName) ?? false
        let roleMatches  = event.elementRole?.localizedCaseInsensitiveContains(step.elementName) ?? false
        let elementMatches = titleMatches || roleMatches

        // --- Final decision ---
        if elementMatches {
            return .correct
        }

        // The event came from the right app but the element didn't match.
        // Only report "incorrect" when we have a bundleID constraint — otherwise
        // we can't tell whether the event is relevant to this step at all.
        if step.appBundleID != nil {
            let actualDescription = event.elementTitle ?? event.elementRole ?? "unknown"
            return .incorrect(
                reason: "Expected \(step.elementName), but got \(actualDescription)"
            )
        }

        return .unrelated
    }

}
