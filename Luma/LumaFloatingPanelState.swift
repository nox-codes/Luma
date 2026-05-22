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

    /// Response text with all internal tags stripped, safe to display to the user.
    /// Removes:
    ///   - [POINT:...] navigation tags (e.g. "[POINT:x,y:label:screen0]")
    ///   - <STEPS>...</STEPS> JSON blocks used by the walkthrough pipeline
    var displayResponse: String {
        guard !response.isEmpty else { return "" }

        var text = response

        // Strip <STEPS>...</STEPS> blocks including all content between them.
        if let stepsRegex = try? NSRegularExpression(
            pattern: #"<STEPS>[\s\S]*?</STEPS>"#
        ) {
            let fullRange = NSRange(text.startIndex..., in: text)
            text = stepsRegex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        }

        // Strip [POINT:...] navigation tags.
        if let pointRegex = try? NSRegularExpression(pattern: #"\[POINT:[^\]]*\]"#) {
            let fullRange = NSRange(text.startIndex..., in: text)
            text = pointRegex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
