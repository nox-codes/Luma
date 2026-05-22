//
//  LumaFloatingPanelState.swift
//  Luma
//
//  Shared observable state for the floating text input panel.
//  Owned by the singleton; observed by both LumaFloatingInputView (to render
//  the response) and LumaFloatingInputWindowManager (to resize the panel).
//  CompanionManager writes response chunks here as they stream in.
//

import Combine
import Foundation

@MainActor
final class FloatingPanelState: ObservableObject {

    static let shared = FloatingPanelState()

    /// The streaming AI response text. Appended to as chunks arrive.
    /// Preserved across hide/show cycles — only cleared when a new message is sent.
    @Published var response: String = ""

    /// True while the AI is actively streaming a response into this panel.
    @Published var isStreaming: Bool = false

    /// The text currently typed in the input field. @Published so the send button
    /// re-renders immediately as the user types — plain var in the window manager
    /// does not notify SwiftUI.
    @Published var draft: String = ""

    /// Response text with internal tags replaced or stripped, safe to display to the user.
    /// Transforms:
    ///   - <STEPS>...</STEPS> JSON blocks → human-readable "Step 1: ..., Step 2: ..." list
    ///   - [POINT:...] navigation tags → removed entirely
    var displayResponse: String {
        guard !response.isEmpty else { return "" }

        var text = response

        // Replace <STEPS>...</STEPS> blocks with a formatted numbered step list.
        // Matches are processed in reverse order so character indices don't shift mid-loop.
        if let stepsRegex = try? NSRegularExpression(pattern: #"<STEPS>([\s\S]*?)</STEPS>"#) {
            let fullRange = NSRange(text.startIndex..., in: text)
            let matches = stepsRegex.matches(in: text, range: fullRange).reversed()
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let formattedSteps: String
                if match.numberOfRanges >= 2, let jsonRange = Range(match.range(at: 1), in: text) {
                    formattedSteps = Self.formattedStepListFromJSON(String(text[jsonRange]))
                } else {
                    formattedSteps = ""
                }
                text.replaceSubrange(matchRange, with: formattedSteps)
            }
        }

        // Strip [POINT:...] navigation tags.
        if let pointRegex = try? NSRegularExpression(pattern: #"\[POINT:[^\]]*\]"#) {
            let fullRange = NSRange(text.startIndex..., in: text)
            text = pointRegex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a STEPS JSON block and returns a markdown-formatted numbered step list.
    /// Uses the same "anchor on 'steps' key" strategy as CompanionManager to tolerate
    /// extra whitespace or wrapper text the AI adds inside the tags.
    /// Returns an empty string when the JSON is absent, malformed, or contains no steps.
    private static func formattedStepListFromJSON(_ jsonContent: String) -> String {
        guard let stepsKeyRange = jsonContent.range(of: "\"steps\""),
              let objectStart = jsonContent[..<stepsKeyRange.lowerBound].lastIndex(of: "{"),
              let objectEnd = jsonContent.lastIndex(of: "}"),
              objectStart <= objectEnd else { return "" }

        let jsonString = String(jsonContent[objectStart...objectEnd])

        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = root["steps"] as? [[String: Any]] else { return "" }

        let stepLines = steps.enumerated().compactMap { (stepIndex, step) -> String? in
            let instruction = step["instruction"] as? String ?? ""
            guard !instruction.isEmpty else { return nil }
            return "**Step \(stepIndex + 1):** \(instruction)"
        }

        guard !stepLines.isEmpty else { return "" }
        return "\n\n" + stepLines.joined(separator: "\n")
    }

    private init() {}

    /// Clear response and mark streaming start. Called by the window manager
    /// when the user submits a new message.
    func beginNewResponse() {
        response = ""
        isStreaming = true
    }

    /// Called by CompanionManager when the full response has been received.
    func finishResponse() {
        isStreaming = false
    }
}
