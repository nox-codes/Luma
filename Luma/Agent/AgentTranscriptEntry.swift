//
//  AgentTranscriptEntry.swift
//  leanring-buddy
//
//  Transcript entry model for agent sessions.
//  Each entry has a role (user, assistant, system, command, plan) and timestamped text.
//

import Foundation

struct AgentTranscriptEntry: Identifiable, Equatable {
    let id: UUID
    let role: TranscriptRole
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: TranscriptRole, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    static func == (lhs: AgentTranscriptEntry, rhs: AgentTranscriptEntry) -> Bool {
        lhs.id == rhs.id
    }
}

enum TranscriptRole: String, Codable {
    case user
    case assistant
    case system
    case command
    case plan
}
