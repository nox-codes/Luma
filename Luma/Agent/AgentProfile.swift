//
//  AgentProfile.swift
//  leanring-buddy
//
//  Per-agent configuration including model selection and identity.
//  Stored in UserDefaults as a JSON-encoded array.
//

import Foundation

/// Supported AI models for agent mode.
enum AgentModel: String, Codable, CaseIterable, Identifiable {
    case claudeSonnet = "claude-sonnet-4-6"
    case claudeOpus  = "claude-opus-4-6"
    case gpt4o       = "gpt-4o"
    case gpt4oMini   = "gpt-4o-mini"

    var id: String { rawValue }

    /// Human-readable display name shown in the model picker UI.
    var displayName: String {
        switch self {
        case .claudeSonnet: return "Claude Sonnet 4.6"
        case .claudeOpus:   return "Claude Opus 4.6"
        case .gpt4o:        return "GPT-4o"
        case .gpt4oMini:    return "GPT-4o Mini"
        }
    }

    /// Provider name for grouping in the UI.
    var providerName: String {
        switch self {
        case .claudeSonnet, .claudeOpus: return "Anthropic"
        case .gpt4o, .gpt4oMini:        return "OpenAI"
        }
    }
}

/// Configuration for a single agent instance, including its assigned model.
struct AgentProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var model: AgentModel

    init(id: UUID = UUID(), name: String = "Agent", model: AgentModel = .claudeSonnet) {
        self.id = id
        self.name = name
        self.model = model
    }
}
