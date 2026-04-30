//
//  LumaWriteEngine.swift
//  leanring-buddy
//
//  Controls all text displayed in the companion bubble. Every bubble display
//  goes through this engine — never raw strings directly. Defines bubble types,
//  error message mapping, and auto-calculated display durations.
//

import Foundation
import SwiftUI

// MARK: - BubbleType

/// Every kind of content the companion bubble can show.
/// The type determines background color, accent treatment, and display duration.
enum BubbleType: Equatable {
    /// Normal AI response — dark background, white text.
    case response

    /// Error state — red background, white text, 5-second hold.
    case error(ErrorType)

    /// Expandable numbered guide — dark background, step list.
    case guide(steps: [String])

    /// Active walkthrough step — dark background, cyan progress indicator.
    case walkthrough(step: Int, total: Int, text: String)

    /// Nudge reminder during walkthrough — dark background, amber left border.
    case nudge(text: String)

    /// Success confirmation — dark background, green left border.
    case success(text: String)

    static func == (lhs: BubbleType, rhs: BubbleType) -> Bool {
        switch (lhs, rhs) {
        case (.response, .response): return true
        case (.error(let a), .error(let b)): return a == b
        case (.guide(let a), .guide(let b)): return a == b
        case (.walkthrough(let sa, let ta, let xa), .walkthrough(let sb, let tb, let xb)):
            return sa == sb && ta == tb && xa == xb
        case (.nudge(let a), .nudge(let b)): return a == b
        case (.success(let a), .success(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - ErrorType

/// All error conditions Luma can surface, each mapping to a human-readable message.
enum ErrorType: Equatable {
    case offline
    case rateLimited
    case noAPIKey
    case connectionFailed(providerName: String)
    case modelNotFound
    case unknown(String)
}

// MARK: - BubbleContent

/// The resolved content ready to pass to the bubble window.
struct BubbleContent {
    let text: String
    let bubbleType: BubbleType
    /// How long to keep the bubble visible before auto-dismissing (nil = stay until replaced).
    let displayDuration: TimeInterval?
    /// Left-border accent color for nudge/success types.
    let accentColor: Color?
    /// Background override (nil = use default dark bg).
    let backgroundOverride: Color?
}

// MARK: - LumaWriteEngine

/// Central authority for all companion bubble text. Call `content(for:text:)` to get a
/// fully resolved BubbleContent — background, duration, accent — ready for display.
@MainActor
final class LumaWriteEngine {
    static let shared = LumaWriteEngine()
    private init() {}

    // MARK: - Public API

    /// Produces a fully resolved BubbleContent for a given type and raw text.
    func content(for bubbleType: BubbleType, text: String = "") -> BubbleContent {
        switch bubbleType {

        case .response:
            let cleanedText = stripMarkdownFormatting(text)
            return BubbleContent(
                text: cleanedText,
                bubbleType: .response,
                displayDuration: displayDuration(for: cleanedText),
                accentColor: nil,
                backgroundOverride: nil
            )

        case .error(let errorType):
            let humanMessage = errorMessage(for: errorType)
            return BubbleContent(
                text: humanMessage,
                bubbleType: .error(errorType),
                displayDuration: 5.0,
                accentColor: nil,
                backgroundOverride: DS.Colors.destructive.opacity(0.9)
            )

        case .guide(let steps):
            let fullText = steps.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let duration = max(Double(steps.count) * 2.0, 6.0)
            return BubbleContent(
                text: fullText,
                bubbleType: .guide(steps: steps),
                displayDuration: min(duration, 12.0),
                accentColor: nil,
                backgroundOverride: nil
            )

        case .walkthrough(let step, let total, let stepText):
            let formatted = "Step \(step) of \(total)\n\(stepText)"
            return BubbleContent(
                text: formatted,
                bubbleType: bubbleType,
                displayDuration: nil, // stays until step completes
                accentColor: Color(hex: "#0A84FF"),
                backgroundOverride: nil
            )

        case .nudge(let nudgeText):
            return BubbleContent(
                text: nudgeText,
                bubbleType: .nudge(text: nudgeText),
                displayDuration: 4.0,
                accentColor: DS.Colors.warning,
                backgroundOverride: nil
            )

        case .success(let successText):
            return BubbleContent(
                text: successText,
                bubbleType: .success(text: successText),
                displayDuration: 3.0,
                accentColor: DS.Colors.success,
                backgroundOverride: nil
            )
        }
    }

    // MARK: - Error Message Mapping

    /// Maps every API error type to a brief, human-readable message.
    /// Raw API error strings are never shown to the user.
    func errorMessage(for errorType: ErrorType) -> String {
        switch errorType {
        case .offline:
            return "You're offline."
        case .rateLimited:
            return "Rate limited — try again in a moment."
        case .noAPIKey:
            return "No API key configured. Add one in Settings."
        case .connectionFailed(let providerName):
            return "Can't reach \(providerName). Check your key."
        case .modelNotFound:
            return "Model not found. Check your model name in Settings."
        case .unknown(let rawMessage):
            return summarizeError(rawMessage)
        }
    }

    // MARK: - Display Duration

    /// Calculates how long to display a bubble based on word count.
    /// Min 3 seconds, max 12 seconds, 0.3 seconds per word.
    func displayDuration(for text: String) -> TimeInterval {
        let wordCount = text.split(separator: " ").count
        let calculatedDuration = 3.0 + (Double(wordCount) * 0.3)
        return min(calculatedDuration, 12.0)
    }

    // MARK: - Internal Helpers

    // MARK: - Agent Control Tag Stripping

    /// Removes any `<NEXT_ACTIONS>…</NEXT_ACTIONS>` block from agent response text.
    /// Called before any text reaches the bubble, TTS, or write engine — the XML
    /// control structure is never shown to the user.
    static func stripAgentControlTags(_ text: String) -> String {
        var result = text
        // Loop to handle multiple blocks (edge case where model emits more than one)
        while let startRange = result.range(of: "<NEXT_ACTIONS>"),
              let endRange = result.range(of: "</NEXT_ACTIONS>"),
              startRange.lowerBound <= endRange.lowerBound {
            result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips agent control tags and normalizes newlines to spaces so any text
    /// flows as one continuous line in the bubble or panel. The display component
    /// wraps at its own max width — newlines in source text should never force breaks.
    static func normalizeForDisplay(_ text: String) -> String {
        let stripped = stripAgentControlTags(text)
        let noNewlines = stripped.replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)
        return noNewlines.trimmingCharacters(in: .whitespaces)
    }

    /// Strips agent control tags then truncates to `maxLength` characters,
    /// breaking at the nearest word boundary.
    static func cleanAndTruncate(_ text: String, maxLength: Int = 150) -> String {
        let stripped = stripAgentControlTags(text)
        guard stripped.count > maxLength else { return stripped }
        let prefix = String(stripped.prefix(maxLength))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }
        return prefix
    }

    // MARK: - Markdown Stripping

    /// Strips markdown formatting characters from AI response text so plain-text
    /// rendering in the bubble doesn't show raw symbols like **, *, _, ##, ``.
    private func stripMarkdownFormatting(_ text: String) -> String {
        // Strip agent control tags first so they never leak through to display
        var result = Self.stripAgentControlTags(text)
        // Bold: **text** → text
        result = result.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "$1", options: .regularExpression)
        // Italic: *text* → text  (after bold to avoid partial matches)
        result = result.replacingOccurrences(of: #"\*([^*\n]+)\*"#, with: "$1", options: .regularExpression)
        // Bold underscore: __text__ → text
        result = result.replacingOccurrences(of: #"__([^_\n]+)__"#, with: "$1", options: .regularExpression)
        // Italic underscore: _text_ → text
        result = result.replacingOccurrences(of: #"_([^_\n]+)_"#, with: "$1", options: .regularExpression)
        // Strikethrough: ~~text~~ → text
        result = result.replacingOccurrences(of: #"~~([^~\n]+)~~"#, with: "$1", options: .regularExpression)
        // Inline code: `code` → code
        result = result.replacingOccurrences(of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)
        // Headings: ### text → text  (anchored to line start)
        result = result.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        // Block quotes: > text → text
        result = result.replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)
        // Collapse any run of newlines (paragraph breaks, line breaks) into a single
        // space so the response flows as one continuous line in the bubble. The bubble
        // itself wraps at its max width, so multi-line layout is driven by available
        // width, not by newline characters in the source text.
        result = result.replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Extracts the most meaningful part of a raw API error string, capped at 8 words.
    private func summarizeError(_ rawMessage: String) -> String {
        // Strip common API boilerplate prefixes
        let stripped = rawMessage
            .replacingOccurrences(of: "Error: ", with: "")
            .replacingOccurrences(of: "error: ", with: "")
            .replacingOccurrences(of: "APIError: ", with: "")

        let words = stripped.split(separator: " ").prefix(8)
        let summary = words.joined(separator: " ")

        // Make sure it ends cleanly
        let trimmed = summary.trimmingCharacters(in: .punctuationCharacters)
        return trimmed.isEmpty ? "Something went wrong." : "\(trimmed)."
    }
}
