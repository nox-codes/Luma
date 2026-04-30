//
//  AgentRuntime.swift
//  leanring-buddy
//
//  Shared protocol for agent execution backends and singleton manager
//  that detects available runtimes. Claude Code CLI is the default when
//  detected; Claude API with tool-use is the fallback.
//

import Combine
import Foundation

// MARK: - Protocol

protocol AgentRuntime: AnyObject {
    /// Start a new agent session. Empty task = warm-up only.
    func startSession(id: UUID, task: String, workingDirectory: String, systemContext: String) async throws

    /// Submit a follow-up prompt to an existing session.
    func submitPrompt(sessionId: UUID, prompt: String) async throws

    /// Stop and tear down a session.
    func stopSession(sessionId: UUID) async

    /// Publishes transcript entries as they arrive from the runtime.
    var transcriptPublisher: AnyPublisher<AgentTranscriptEntry, Never> { get }

    /// Publishes session status changes.
    var statusPublisher: AnyPublisher<(UUID, AgentSessionStatus), Never> { get }
}

// MARK: - Runtime Type

enum AgentRuntimeType: String, CaseIterable {
    case claudeCode = "Claude Code"
    case claudeAPI = "Claude API"
}

// MARK: - Errors

enum AgentRuntimeError: LocalizedError {
    case executableNotFound(String)
    case sessionNotFound(UUID)
    case maxIterationsReached

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): return "Executable not found at \(path)"
        case .sessionNotFound(let id): return "Session \(id) not found"
        case .maxIterationsReached: return "Maximum tool-use iterations reached"
        }
    }
}

// MARK: - Runtime Manager

/// Singleton that detects available runtimes and creates the appropriate one.
@MainActor
final class AgentRuntimeManager: ObservableObject {
    static let shared = AgentRuntimeManager()

    @Published private(set) var detectedRuntimeType: AgentRuntimeType = .claudeAPI
    @Published private(set) var claudeCodePath: String?

    private let userOverrideKey = "luma.agentRuntime.override"

    var effectiveRuntimeType: AgentRuntimeType {
        let override = UserDefaults.standard.string(forKey: userOverrideKey)
        switch override {
        case "claudeCode":
            return claudeCodePath != nil ? .claudeCode : .claudeAPI
        case "claudeAPI":
            return .claudeAPI
        default:
            return detectedRuntimeType
        }
    }

    private init() {
        detectRuntime()
    }

    func detectRuntime() {
        let knownPaths = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/bin/claude",
            "/usr/bin/claude"
        ]

        // Check PATH via which
        if let whichPath = Self.runWhichClaude() {
            claudeCodePath = whichPath
            detectedRuntimeType = .claudeCode
            LumaLogger.log("[Luma] Detected Claude Code CLI at \(whichPath)")
            return
        }

        // Check known install locations
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                claudeCodePath = path
                detectedRuntimeType = .claudeCode
                LumaLogger.log("[Luma] Detected Claude Code CLI at \(path)")
                return
            }
        }

        claudeCodePath = nil
        detectedRuntimeType = .claudeAPI
        LumaLogger.log("[Luma] Claude Code CLI not found, using API fallback")
    }

    func createRuntime() -> any AgentRuntime {
        switch effectiveRuntimeType {
        case .claudeCode:
            guard let path = claudeCodePath else {
                return ClaudeAPIAgentRuntime()
            }
            return ClaudeCodeAgentRuntime(executablePath: path)
        case .claudeAPI:
            return ClaudeAPIAgentRuntime()
        }
    }

    func setOverride(_ type: String) {
        UserDefaults.standard.set(type, forKey: userOverrideKey)
    }

    private static func runWhichClaude() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "which claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty {
                    return path
                }
            }
        } catch {}

        return nil
    }
}
