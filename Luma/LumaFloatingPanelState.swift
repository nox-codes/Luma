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

    /// Response text with all internal [POINT:...] navigation tags stripped.
    /// Always use this for display — the raw response may contain tags that look
    /// like "[POINT:none]" or "[POINT:x,y:label:screen0]".
    var displayResponse: String {
        guard !response.isEmpty else { return "" }
        // Pattern matches [POINT:...] tags with any content between brackets
        guard let regex = try? NSRegularExpression(pattern: #"\[POINT:[^\]]*\]"#) else {
            return response
        }
        let range = NSRange(response.startIndex..., in: response)
        return regex.stringByReplacingMatches(in: response, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
