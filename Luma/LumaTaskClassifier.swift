//
//  LumaTaskClassifier.swift
//  leanring-buddy
//
//  Classifies user input to decide how Luma should respond:
//  singleStep (one action), multiStep (needs a walkthrough), question (pure info),
//  or unknown. Also classifies accessibility events to detect wrong actions.
//
//  Uses keyword-based heuristics that run entirely on-device with no API call.
//  When a DistilBERT Core ML model is bundled, the model path takes over.
//

import Foundation

// MARK: - TaskType

/// How a piece of user input should be handled.
enum TaskType: Equatable {
    /// One direct action — use a single AI response, no walkthrough needed.
    case singleStep
    /// Multiple ordered actions — spin up the WalkthroughEngine.
    case multiStep
    /// A "what is / how does / why" question — respond with information, no cursor pointing.
    case question
    /// Couldn't determine intent.
    case unknown
}

// MARK: - TaskClassification

struct TaskClassification {
    let taskType: TaskType
    /// 0.0–1.0 confidence in the classification.
    let confidence: Double
    /// Human-readable explanation for debugging.
    let reason: String
}

// MARK: - WrongActionResult

/// Result of checking whether a user action matches the expected walkthrough step.
enum WrongActionResult: Equatable {
    case correct
    case incorrect(reason: String)
    case unrelated
}

// MARK: - LumaTaskClassifier

/// On-device task classifier using keyword heuristics.
/// Produces instant results with no API latency.
///
/// When DistilBERT.mlmodel is bundled, the model inference path should replace
/// the heuristic fallback. Until then, heuristics handle the full load.
final class LumaTaskClassifier {
    static let shared = LumaTaskClassifier()

    private(set) var isModelAvailable: Bool = false

    private init() {
        checkForModel()
    }

    private func checkForModel() {
        let modelExists = Bundle.main.url(forResource: "DistilBERT", withExtension: "mlmodel") != nil
            || Bundle.main.url(forResource: "DistilBERT", withExtension: "mlpackage") != nil
        isModelAvailable = modelExists
        if modelExists {
            LumaLogger.log("[LumaClassifier] DistilBERT model found — ML classification available.")
        } else {
            LumaLogger.log("[LumaClassifier] DistilBERT model not bundled — using keyword heuristics.")
        }
    }

    // MARK: - Task Classification

    /// Classifies user text to determine how Luma should handle it.
    func classifyTask(_ text: String) async -> TaskClassification {
        // If the ML model were loaded, run it here.
        // For now, use keyword heuristics which work well for common cases.
        return heuristicClassify(text)
    }

    // MARK: - Wrong Action Detection

    /// Checks whether an accessibility event represents the correct action for `step`.
    /// Used during walkthrough execution to validate user actions on-device without an API call.
    func detectWrongAction(
        expectedElementName: String,
        expectedAppBundleID: String?,
        actualEventElementTitle: String?,
        actualEventAppBundleID: String
    ) -> WrongActionResult {
        // Bundle ID check — wrong app means unrelated, not wrong-element
        if let expectedBundle = expectedAppBundleID,
           !actualEventAppBundleID.isEmpty,
           actualEventAppBundleID != expectedBundle {
            return .unrelated
        }

        guard let actualTitle = actualEventElementTitle, !actualTitle.isEmpty else {
            return .unrelated
        }

        let actualLower = actualTitle.lowercased()
        let expectedLower = expectedElementName.lowercased()

        if actualLower == expectedLower || actualLower.contains(expectedLower) {
            return .correct
        }

        return .incorrect(reason: "Expected '\(expectedElementName)' but got '\(actualTitle)'")
    }

    // MARK: - Keyword Heuristics

    private func heuristicClassify(_ text: String) -> TaskClassification {
        let lowercased = text.lowercased()
        let wordCount = text.split(separator: " ").count

        // Multi-step indicators — checked FIRST because procedural phrases like
        // "how do I..." and "tell me how to..." would otherwise be caught by the
        // question keyword list below before reaching this check.
        // Procedural requests always win over informational patterns.
        let strongMultiStepPhrases = [
            // Procedure-seeking — how to do something step by step
            "how to", "how do i", "how do you", "how can i", "how can you",
            "how would i", "how should i",
            "steps to", "steps for", "step by step",
            // Guidance phrases
            "guide me", "walk me through", "walk through",
            "show me how", "take me through",
            "tell me how to",       // "tell me how to compress" is procedural
            // Task-specific verbs that almost always require multiple UI actions
            "set up", "configure", "install", "uninstall",
            "compress", "zip", "back up", "backup", "transfer files",
            "move a file", "move my", "rename a", "rename the",
            "delete a", "delete the", "create a", "create the",
            "make a folder", "make a file", "export", "import", "convert",
            // "help me [verb]" patterns for common tasks
            "help me move", "help me save", "help me create", "help me delete",
            "help me install", "help me compress", "help me set up",
            "help me configure", "help me export", "help me import",
            "help me back up", "help me transfer",
            // Sequential connectors — two distinct actions joined by "and" or "then".
            // These fire even when the request starts with a simple verb like "open",
            // which would otherwise be caught by the singleStepPrefixes check below.
            // e.g. "open Safari and go to google.com", "click File then choose Save As"
            "and go to", "and navigate to", "and navigate",
            "and open", "and click", "and type", "and search",
            "and select", "and download", "and log in", "and sign in",
            "and then go", "and then open", "and then click", "and then navigate",
            "then go to", "then navigate to", "then navigate",
            "then open", "then click", "then type", "then search",
            "then select", "then download", "then log in", "then sign in",
        ]
        // Require at least one strong phrase AND at least 3 words to be a real task request
        let multiStepMatchCount = strongMultiStepPhrases.filter { lowercased.contains($0) }.count
        if multiStepMatchCount >= 1 && wordCount >= 3 {
            return TaskClassification(
                taskType: .multiStep,
                confidence: min(0.6 + Double(multiStepMatchCount) * 0.1, 0.9),
                reason: "Multi-step phrase detected (\(multiStepMatchCount) match(es))"
            )
        }

        // Sequential multi-step fallback: two or more recognisable action verbs present
        // in a single request, even when they aren't joined by the explicit connector
        // phrases above. Covers patterns like "open X, navigate to Y" (comma instead of
        // "and") and cases where compressPrompt removed the connector word.
        let actionVerbs: [String] = [
            "open", "go to", "navigate", "click", "find", "type",
            "search", "select", "download", "save", "close", "quit", "launch",
        ]
        let distinctActionVerbCount = actionVerbs.filter { lowercased.contains($0) }.count
        if distinctActionVerbCount >= 2 && wordCount >= 4 {
            return TaskClassification(
                taskType: .multiStep,
                confidence: 0.80,
                reason: "Multiple action verbs detected (\(distinctActionVerbCount) verb(s))"
            )
        }

        // Question patterns — informational, no action needed.
        // "how do i" and "how do you" are intentionally absent here —
        // they are procedural and belong in the multi-step path above.
        let questionKeywords = [
            "what is", "what are", "what does", "what's", "whats",
            "how does", "how did",          // "how does X work" — mechanics/explanation
            "why is", "why does", "why are", "why did",
            "explain", "tell me about", "tell me what", "tell me why",
            "tell me how",                  // "tell me how X works" — without "to"
            "can you explain", "can you describe",
            "define", "describe", "help me understand",
        ]
        if questionKeywords.contains(where: { lowercased.hasPrefix($0) || lowercased.contains($0) }) {
            return TaskClassification(taskType: .question, confidence: 0.8, reason: "Question pattern detected")
        }

        // Single-step patterns — short direct commands that refer to one UI action.
        // Guard: "and"/"then" signals a second action is present, so even a request
        // that starts with "open" or "click" is multi-step in that case and must not
        // short-circuit here (e.g. "open Safari and go to google.com").
        let hasSequentialConnector = lowercased.contains(" and ") || lowercased.contains(" then ")
        let singleStepPrefixes = [
            "click", "open", "find", "show", "where is", "locate", "go to",
            "navigate to", "point to", "look at"
        ]
        if singleStepPrefixes.contains(where: { lowercased.hasPrefix($0) })
            && wordCount <= 8
            && !hasSequentialConnector {
            return TaskClassification(taskType: .singleStep, confidence: 0.75, reason: "Short direct command")
        }

        // Default: send to the voice response path. It handles questions, general requests,
        // and conversational input well. The WalkthroughEngine path should only activate
        // when there's a clear procedural signal above — never by default.
        return TaskClassification(taskType: .singleStep, confidence: 0.5, reason: "No specific pattern — defaulting to voice response")
    }
}
