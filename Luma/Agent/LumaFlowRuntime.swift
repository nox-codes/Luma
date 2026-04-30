//
//  LumaFlowRuntime.swift
//  leanring-buddy
//
//  Thin AgentRuntime bridge that LumaFlowEngine drives directly.
//  Instead of spawning a subprocess or making tool-use API calls, the engine
//  calls publishEntry() and publishStatus() to inject transcript entries and
//  status changes that AgentSession's Combine subscriptions consume for UI.
//
//  submitPrompt() is wired to accept follow-up prompts from the user
//  (typed in the dock bubble text field) during a running flow session.
//

import Combine
import Foundation

// MARK: - LumaFlowRuntime

final class LumaFlowRuntime: AgentRuntime {

    // MARK: - Publishers

    private let transcriptSubject = PassthroughSubject<AgentTranscriptEntry, Never>()
    private let statusSubject     = PassthroughSubject<(UUID, AgentSessionStatus), Never>()

    var transcriptPublisher: AnyPublisher<AgentTranscriptEntry, Never> {
        transcriptSubject.eraseToAnyPublisher()
    }

    var statusPublisher: AnyPublisher<(UUID, AgentSessionStatus), Never> {
        statusSubject.eraseToAnyPublisher()
    }

    // MARK: - Engine-Driven Publishing

    /// Injects a transcript entry into the session (visible in the dock bubble transcript).
    func publishEntry(_ entry: AgentTranscriptEntry) {
        transcriptSubject.send(entry)
    }

    /// Injects a status change — transitions the session between stopped/starting/running/ready/failed.
    func publishStatus(sessionId: UUID, status: AgentSessionStatus) {
        statusSubject.send((sessionId, status))
    }

    // MARK: - AgentRuntime Protocol

    /// Called by AgentSession.warmUp() — flow sessions are always ready immediately.
    func startSession(id: UUID, task: String, workingDirectory: String, systemContext: String) async throws {
        publishStatus(sessionId: id, status: .ready)
    }

    /// Called when the user types a follow-up in the dock bubble during a flow session.
    /// The engine observes this via the `followUpSubject` publisher below.
    func submitPrompt(sessionId: UUID, prompt: String) async throws {
        followUpSubject.send(prompt)
    }

    /// Called when the dock bubble dismiss button is pressed.
    func stopSession(sessionId: UUID) async {
        publishStatus(sessionId: sessionId, status: .stopped)
    }

    // MARK: - Follow-Up Relay

    /// Publishes follow-up prompts typed by the user so the engine can inject them
    /// into its recovery or ask-user loops without breaking the AgentRuntime contract.
    let followUpSubject = PassthroughSubject<String, Never>()
}
