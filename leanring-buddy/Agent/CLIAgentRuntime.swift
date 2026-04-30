//
//  CLIAgentRuntime.swift
//  leanring-buddy
//
//  AgentRuntime implementation that executes a single shell command and
//  streams its stdout/stderr output as transcript entries. Used by the
//  classifier's .cli path so CLI tasks appear as a proper agent bubble
//  in the dock rather than only speaking the result.
//
//  One CLIAgentRuntime is created per CLI task. It is not re-used between
//  sessions — create a new instance for each command.
//

import Combine
import Foundation

// MARK: - CLIAgentRuntime

/// AgentRuntime backend that runs a zsh shell command and streams its output.
/// Status transitions: stopped → starting → running → ready (or failed).
final class CLIAgentRuntime: AgentRuntime {

    // MARK: - Publishers

    private let transcriptSubject = PassthroughSubject<AgentTranscriptEntry, Never>()
    private let statusSubject = PassthroughSubject<(UUID, AgentSessionStatus), Never>()

    var transcriptPublisher: AnyPublisher<AgentTranscriptEntry, Never> {
        transcriptSubject.eraseToAnyPublisher()
    }

    var statusPublisher: AnyPublisher<(UUID, AgentSessionStatus), Never> {
        statusSubject.eraseToAnyPublisher()
    }

    // MARK: - State

    private var activeSessionId: UUID?
    private var runningProcess: Process?
    private var outputCollectionTask: Task<Void, Never>?

    // MARK: - AgentRuntime Protocol

    func startSession(id: UUID, task: String, workingDirectory: String, systemContext: String) async throws {
        // CLIAgentRuntime treats startSession as a no-op warm-up;
        // the actual command is sent via submitPrompt.
        activeSessionId = id
        statusSubject.send((id, .ready))
    }

    /// Runs the shell command stored in `prompt`. The prompt should be the
    /// raw shell command string — CLIAgentRuntime wraps it in /bin/zsh -c.
    func submitPrompt(sessionId: UUID, prompt: String) async throws {
        activeSessionId = sessionId
        statusSubject.send((sessionId, .running))

        // Emit a command entry so the progress section shows the running command
        transcriptSubject.send(AgentTranscriptEntry(role: .command, text: "[bash] \(prompt)"))

        do {
            let output = try await runShellCommand(prompt, sessionId: sessionId)
            // Emit the output as an assistant message so it appears in the transcript
            transcriptSubject.send(AgentTranscriptEntry(role: .assistant, text: output))
            statusSubject.send((sessionId, .ready))
        } catch let error as CLIRuntimeError {
            let errorText = error.localizedDescription
            transcriptSubject.send(AgentTranscriptEntry(role: .system, text: "Error: \(errorText)"))
            statusSubject.send((sessionId, .failed(errorText)))
        } catch {
            let errorText = error.localizedDescription
            transcriptSubject.send(AgentTranscriptEntry(role: .system, text: "Error: \(errorText)"))
            statusSubject.send((sessionId, .failed(errorText)))
        }
    }

    func stopSession(sessionId: UUID) async {
        runningProcess?.terminate()
        runningProcess = nil
        outputCollectionTask?.cancel()
        outputCollectionTask = nil
        if let sessionId = activeSessionId {
            statusSubject.send((sessionId, .stopped))
        }
        activeSessionId = nil
    }

    // MARK: - Shell Execution

    /// Executes the given shell command via /bin/zsh -c and returns combined stdout+stderr.
    /// Streams output lines as system transcript entries while the command runs,
    /// then returns the full output when the process exits.
    private func runShellCommand(_ command: String, sessionId: UUID) async throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Use -l (login shell) so .zprofile is sourced and the user's full PATH
        // is available — Homebrew, Node, Python, etc. are not on the system PATH
        // that non-login shells inherit from a sandboxed macOS app process.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        runningProcess = process

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CLIRuntimeError.launchFailed(error.localizedDescription))
                return
            }

            // Collect output on a background thread to avoid blocking the main actor
            outputCollectionTask = Task.detached {
                var stdoutData = Data()
                var stderrData = Data()

                // Read stdout and stderr to completion
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()

                let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

                // Combine stdout and stderr; trim trailing whitespace
                var fullOutput = stdoutString
                if !stderrString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fullOutput += stderrString
                }
                fullOutput = fullOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                // Truncate very long output so the card doesn't overflow
                let maxOutputCharacters = 2000
                if fullOutput.count > maxOutputCharacters {
                    fullOutput = String(fullOutput.prefix(maxOutputCharacters)) + "\n…(output truncated)"
                }

                let exitCode = process.terminationStatus
                if exitCode == 0 || !fullOutput.isEmpty {
                    // Treat exit 0 and any output as success
                    continuation.resume(returning: fullOutput.isEmpty ? "(no output)" : fullOutput)
                } else {
                    continuation.resume(throwing: CLIRuntimeError.nonZeroExit(exitCode, fullOutput))
                }
            }
        }
    }
}

// MARK: - Errors

enum CLIRuntimeError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Failed to launch process: \(message)"
        case .nonZeroExit(let code, let output):
            let outputSuffix = output.isEmpty ? "" : "\n\(output)"
            return "Command exited with code \(code)\(outputSuffix)"
        }
    }
}
