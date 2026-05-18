//
//  ClaudeCodeAgentRuntime.swift
//  leanring-buddy
//
//  Agent runtime that spawns the `claude` CLI as a subprocess.
//  Mirrors OpenClicky's CodexProcessManager subprocess pattern.
//  Streams JSON output for transcript entries, one Process per session.
//

import Combine
import Foundation

final class ClaudeCodeAgentRuntime: AgentRuntime {
    private let executablePath: String
    private var processes: [UUID: Process] = [:]
    private var outputBuffers: [UUID: Data] = [:]
    private let stateQueue = DispatchQueue(label: "com.luma.claude-code-runtime")

    private let transcriptSubject = PassthroughSubject<AgentTranscriptEntry, Never>()
    private let statusSubject = PassthroughSubject<(UUID, AgentSessionStatus), Never>()

    var transcriptPublisher: AnyPublisher<AgentTranscriptEntry, Never> {
        transcriptSubject.eraseToAnyPublisher()
    }

    var statusPublisher: AnyPublisher<(UUID, AgentSessionStatus), Never> {
        statusSubject.eraseToAnyPublisher()
    }

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func startSession(id: UUID, task: String, workingDirectory: String, systemContext: String) async throws {
        statusSubject.send((id, .starting))

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            statusSubject.send((id, .failed("Claude CLI not found at \(executablePath)")))
            throw AgentRuntimeError.executableNotFound(executablePath)
        }

        // Empty task = warm-up, just verify binary exists
        if task.isEmpty {
            statusSubject.send((id, .ready))
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)

        var arguments = [
            "-p", task,
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions"
        ]

        if !systemContext.isEmpty {
            arguments += ["--append-system-prompt", systemContext]
        }

        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "luma-agent"
        process.environment = environment

        stateQueue.sync {
            processes[id] = process
            outputBuffers[id] = Data()
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.handleOutputData(data, sessionId: id)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async {
                let entry = AgentTranscriptEntry(role: .system, text: "[stderr] \(trimmed)")
                self?.transcriptSubject.send(entry)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stateQueue.sync {
                self.processes.removeValue(forKey: id)
                self.outputBuffers.removeValue(forKey: id)
            }

            let terminationStatus = proc.terminationStatus
            DispatchQueue.main.async {
                if terminationStatus == 0 {
                    self.statusSubject.send((id, .ready))
                } else {
                    self.statusSubject.send((id, .failed("Process exited with code \(terminationStatus)")))
                }
            }
        }

        do {
            try process.run()
            statusSubject.send((id, .running))
        } catch {
            stateQueue.sync {
                processes.removeValue(forKey: id)
                outputBuffers.removeValue(forKey: id)
            }
            statusSubject.send((id, .failed(error.localizedDescription)))
            throw error
        }
    }

    func submitPrompt(sessionId: UUID, prompt: String) async throws {
        // Load the combined memory + behavioral outlook prefix so the CLI agent always has
        // full user context. Falls back to empty string if no memory or profile exists yet.
        var systemContext = AgentMemoryIntegration.fullSystemContextPrefix() ?? ""
        let workingDirectory = UserDefaults.standard.string(forKey: "luma.agent.workingDirectory") ?? NSHomeDirectory()

        // Append persona, file-storage defaults, and completion format so the CLI agent
        // responds warmly, saves files to Desktop by default, and always ends with a
        // clean one-liner that Luma can speak and display.
        let desktopPath = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")

        let completionFormat = """
        You are Luma, a helpful macOS assistant. Be warm, direct, and conversational — \
        like a knowledgeable colleague, not a robot. Never use emojis. \
        CRITICAL: Never start your response with the user's request rephrased as a heading, \
        title, bold introduction, or any form of "Task: X" or "**X**" — jump directly into \
        the answer. Never mention your session name or task title anywhere in a response.

        FILE STORAGE (strictly enforced):
        - When creating any file and the user hasn't specified a location, ALWAYS save to \
          \(desktopPath)/.
        - When a task produces written content (essays, reports, stories, summaries, code, \
          or any text output over 25 words or 150 characters), automatically save it as a \
          .txt file on the Desktop (e.g., \(desktopPath)/task_name.txt). Choose a concise, \
          meaningful filename based on the task. No spaces in filenames — use underscores.
        - ALWAYS include the full file path in your completion summary so Luma can open it \
          for the user.

        COMPLETION FORMAT (strictly enforced): When you finish a task, your final message \
        must be one conversational sentence, 150 characters maximum. No title prefix like \
        "Task Complete —". If you saved a file, include its path. \
        Example: "Wrote your essay to \(desktopPath)/essay_title.txt. Anything else?" \
        Then immediately append (tags at end only, never in body text):
        <NEXT_ACTIONS>
        [Short follow-up phrase 1]
        [Short follow-up phrase 2]
        </NEXT_ACTIONS>
        """

        if systemContext.isEmpty {
            systemContext = completionFormat
        } else {
            systemContext += "\n\n\(completionFormat)"
        }

        try await startSession(
            id: sessionId,
            task: prompt,
            workingDirectory: workingDirectory,
            systemContext: systemContext
        )
    }

    func stopSession(sessionId: UUID) async {
        stateQueue.sync {
            guard let process = processes[sessionId] else { return }
            process.terminate()

            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.stateQueue.sync {
                    if let proc = self?.processes[sessionId], proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    // MARK: - Output Parsing

    private func handleOutputData(_ data: Data, sessionId: UUID) {
        stateQueue.sync {
            outputBuffers[sessionId, default: Data()].append(data)
        }

        var buffer: Data = stateQueue.sync { outputBuffers[sessionId] ?? Data() }

        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                parseStreamJsonLine(line, sessionId: sessionId)
            }
        }

        stateQueue.sync {
            outputBuffers[sessionId] = buffer
        }
    }

    private func parseStreamJsonLine(_ line: String, sessionId: UUID) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let entry = AgentTranscriptEntry(role: .assistant, text: line)
            transcriptSubject.send(entry)
            return
        }

        let messageType = json["type"] as? String ?? ""

        switch messageType {
        case "assistant":
            if let content = json["content"] as? [[String: Any]] {
                for block in content {
                    if let text = block["text"] as? String, !text.isEmpty {
                        transcriptSubject.send(AgentTranscriptEntry(role: .assistant, text: text))
                    }
                }
            } else if let message = json["message"] as? String {
                transcriptSubject.send(AgentTranscriptEntry(role: .assistant, text: message))
            }

        case "tool_use", "tool_result":
            let toolName = json["name"] as? String ?? "tool"
            let toolInput = json["input"] as? String ?? ""
            let text = "[\(toolName)] \(toolInput)".trimmingCharacters(in: .whitespacesAndNewlines)
            transcriptSubject.send(AgentTranscriptEntry(role: .command, text: text))

        case "result":
            if let resultText = json["result"] as? String {
                transcriptSubject.send(AgentTranscriptEntry(role: .assistant, text: resultText))
            }
            statusSubject.send((sessionId, .ready))

        case "error":
            let errorMessage = json["error"] as? String ?? "Unknown error"
            transcriptSubject.send(AgentTranscriptEntry(role: .system, text: "Error: \(errorMessage)"))
            statusSubject.send((sessionId, .failed(errorMessage)))

        case "system":
            if let text = json["text"] as? String ?? json["message"] as? String {
                transcriptSubject.send(AgentTranscriptEntry(role: .system, text: text))
            }

        default:
            if let text = json["content"] as? String ?? json["message"] as? String ?? json["text"] as? String {
                transcriptSubject.send(AgentTranscriptEntry(role: .assistant, text: text))
            }
        }
    }
}
