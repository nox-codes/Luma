//
//  LumaLogger.swift
//  leanring-buddy
//
//  Thread-safe file-based logger for Luma.
//  Writes all [Luma], [LIPE], [LumaMobileNet], and [LumaML] diagnostic messages
//  to ~/Library/Logs/Luma/luma.log, auto-rotating when the file reaches 2 MB.
//  Works in both Debug and Release builds — no #if DEBUG guard.
//

import Combine
import Foundation

/// Thread-safe file logger that persists Luma diagnostic output to disk.
///
/// Usage: replace `print("[Luma] ...")` with `LumaLogger.log("[Luma] ...")`
/// The logger echoes to stdout (Xcode console) AND writes to the log file,
/// so existing debug workflows are unaffected.
///
/// Log location:  ~/Library/Logs/Luma/luma.log
/// Rotation:      When luma.log reaches 2 MB it is renamed to luma.log.1
///                and a fresh luma.log is started. Only one backup is kept.
///
/// Real-time streaming: subscribe to `liveLogEntryPublisher` to receive
/// formatted log lines as they are written (used by the Log Window).
final class LumaLogger: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = LumaLogger()

    // MARK: - Real-Time Streaming

    /// Publisher that emits each formatted log line (with timestamp) as it is written.
    /// Subscribers receive lines on the main queue for UI safety.
    let liveLogEntryPublisher = PassthroughSubject<String, Never>()

    // MARK: - Configuration

    /// Maximum size of luma.log before rotation (2 MB).
    private let maximumLogFileSizeInBytes: Int = 2 * 1024 * 1024

    // MARK: - File URLs

    private let logFileURL: URL
    private let rotatedLogFileURL: URL

    // MARK: - Threading

    /// Serial queue — all file I/O funnels through here so writes never race rotations.
    private let writeQueue = DispatchQueue(label: "com.luma.logger.write", qos: .utility)

    // MARK: - File Handle

    private var fileHandle: FileHandle?

    // MARK: - Date Formatting

    /// Cached formatter. Created once on the write queue and only accessed there,
    /// so the non-thread-safe DateFormatter is safe to reuse.
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: - Init

    private init() {
        let lumaLogsDirectoryURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Luma", isDirectory: true)

        logFileURL        = lumaLogsDirectoryURL.appendingPathComponent("luma.log")
        rotatedLogFileURL = lumaLogsDirectoryURL.appendingPathComponent("luma.log.1")

        createLogDirectoryIfNeeded(at: lumaLogsDirectoryURL)
        openOrCreateFileHandle()
    }

    // MARK: - Public API

    /// Logs a message to the on-disk log file and echoes it to stdout.
    /// Call this instead of `print()` for any [Luma], [LIPE], [LumaMobileNet],
    /// or [LumaML] tagged message.
    static func log(_ message: String) {
        // Echo to stdout so Xcode console output is preserved during development.
        print(message)
        shared.writeMessageToFile(message)
    }

    /// Returns the full contents of the current log file, or nil if unreadable.
    /// Used by the Settings → General "Copy Logs" button.
    static func readCurrentLogFileContents() -> String? {
        return try? String(contentsOf: shared.logFileURL, encoding: .utf8)
    }

    // MARK: - Private: Setup

    private func createLogDirectoryIfNeeded(at directoryURL: URL) {
        guard !FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func openOrCreateFileHandle() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    // MARK: - Private: Writing

    private func writeMessageToFile(_ message: String) {
        writeQueue.async { [weak self] in
            guard let self else { return }

            let timestamp = self.timestampFormatter.string(from: Date())
            let logLine   = "[\(timestamp)] \(message)"

            guard let lineData = "\(logLine)\n".data(using: .utf8) else { return }

            // Rotate first so the new line always lands in a fresh file if needed.
            self.rotateLogFileIfSizeExceedsLimit()
            self.fileHandle?.write(lineData)

            // Publish to live subscribers (log window) on main queue
            DispatchQueue.main.async {
                self.liveLogEntryPublisher.send(logLine)
            }
        }
    }

    // MARK: - Private: Rotation

    private func rotateLogFileIfSizeExceedsLimit() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
            let currentFileSizeInBytes = attributes[.size] as? Int,
            currentFileSizeInBytes >= maximumLogFileSizeInBytes
        else { return }

        // Close the active handle before moving the file — FileManager requires this on macOS.
        fileHandle?.closeFile()
        fileHandle = nil

        let fileManager = FileManager.default

        // Remove the previous backup so the rename can succeed.
        try? fileManager.removeItem(at: rotatedLogFileURL)

        // Rename luma.log → luma.log.1.
        try? fileManager.moveItem(at: logFileURL, to: rotatedLogFileURL)

        // Create a fresh luma.log and open a write handle to it.
        fileManager.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
    }
}
