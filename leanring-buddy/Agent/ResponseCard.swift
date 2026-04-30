//
//  ResponseCard.swift
//  leanring-buddy
//
//  Response card model for agent and voice responses.
//  Parses suggested next actions from <NEXT_ACTIONS> tags.
//  Provides truncated text for compact display contexts.
//

import Foundation

struct ResponseCard: Identifiable {
    let id: UUID
    let source: ResponseCardSource
    var rawText: String
    var contextTitle: String?
    var suggestedActions: [String]

    init(id: UUID = UUID(), source: ResponseCardSource, rawText: String, contextTitle: String? = nil) {
        self.id = id
        self.source = source
        self.contextTitle = contextTitle

        var cleanedText = rawText
        var parsedActions: [String] = []

        if let startRange = rawText.range(of: "<NEXT_ACTIONS>"),
           let endRange = rawText.range(of: "</NEXT_ACTIONS>") {
            let actionsText = String(rawText[startRange.upperBound..<endRange.lowerBound])
            parsedActions = actionsText
                .components(separatedBy: "\n")
                .map { line -> String in
                    var action = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Strip surrounding square brackets that some models add, e.g. [Action text]
                    if action.hasPrefix("[") && action.hasSuffix("]") {
                        action = String(action.dropFirst().dropLast())
                    }
                    return action
                }
                .filter { !$0.isEmpty }
            parsedActions = Array(parsedActions.prefix(2))
            cleanedText = rawText.replacingCharacters(
                in: startRange.lowerBound..<endRange.upperBound,
                with: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        self.rawText = cleanedText
        self.suggestedActions = parsedActions
    }

    var truncatedText: String {
        guard rawText.count > 220 else { return rawText }
        let truncated = String(rawText.prefix(220))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }
        return truncated + "..."
    }
}

enum ResponseCardSource: String {
    case voice
    case agent
    case handoff
}
