//
//  LumaAppIntegrations.swift
//  leanring-buddy
//
//  Built-in action modules for common macOS apps and system controls.
//  Used by LumaFlowEngine when the agent needs reliable, direct integration
//  rather than screenshot-only AX traversal.
//
//  Modules:
//    - LumaIntegrationError:       typed errors for integration failures
//    - LumaAppActivator:           activate or launch apps, wait for frontmost
//    - LumaBrowserIntegration:     open URLs, read page content via AX
//    - LumaFinderIntegration:      open/create/move/copy/trash via NSFileManager
//    - LumaNotesIntegration:       create/append/read notes via AppleScript
//    - LumaSystemControlIntegration: volume (CoreAudio), brightness (IOKit), Wi-Fi (networksetup)
//

import AppKit
import CoreAudio
import Foundation
import IOKit
import IOKit.graphics

// MARK: - Integration Errors

enum LumaIntegrationError: LocalizedError {
    case appNotRunning(String)
    case appActivationTimeout(String)
    case urlInvalid(String)
    case scriptFailed(String)
    case permissionDenied(String)
    case elementNotFound(String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let name):        return "App '\(name)' is not running"
        case .appActivationTimeout(let name): return "App '\(name)' did not become frontmost within timeout"
        case .urlInvalid(let url):            return "Invalid URL: '\(url)'"
        case .scriptFailed(let msg):          return "Script failed: \(msg)"
        case .permissionDenied(let msg):      return "Permission denied: \(msg)"
        case .elementNotFound(let msg):       return "Element not found: \(msg)"
        }
    }
}

// MARK: - App Activator

/// Activates or launches apps by display name, waiting for them to become frontmost.
/// Centralises the "is the app running? open it if not, then wait" pattern that
/// every integration needs before it can reliably interact with the app's AX tree.
enum LumaAppActivator {

    /// Activates an app by display name. Launches it from /Applications if not running.
    /// Polls until the app is frontmost or `timeoutSeconds` elapses.
    @discardableResult
    static func activateApp(named appName: String, timeoutSeconds: Double = 6) async throws -> NSRunningApplication {
        // If already running, bring it to front and wait
        if let runningApp = findRunningApp(named: appName) {
            runningApp.activate(options: [.activateIgnoringOtherApps])
            try await waitForAppToBeFrontmost(named: appName, timeoutSeconds: timeoutSeconds)
            return runningApp
        }

        // Not running — look up bundle ID and use NSWorkspace for reliable launch
        if let bundleID = bundleIDForAppName(appName) {
            NSWorkspace.shared.launchApplication(
                withBundleIdentifier: bundleID,
                options: [.default],
                additionalEventParamDescriptor: nil,
                launchIdentifier: nil
            )
        } else {
            // Fallback: open by path
            let appURL = URL(fileURLWithPath: "/Applications/\(appName).app")
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                throw LumaIntegrationError.appNotRunning("'\(appName)' not found at /Applications/\(appName).app")
            }
            NSWorkspace.shared.open(appURL)
        }

        try await waitForAppToBeFrontmost(named: appName, timeoutSeconds: timeoutSeconds)

        guard let runningApp = findRunningApp(named: appName) else {
            throw LumaIntegrationError.appActivationTimeout(appName)
        }
        return runningApp
    }

    /// Returns true if an application with `appName` (case-insensitive) is currently running.
    static func isAppRunning(named appName: String) -> Bool {
        findRunningApp(named: appName) != nil
    }

    // MARK: - Private Helpers

    private static func findRunningApp(named appName: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == appName.lowercased()
        }
    }

    private static func waitForAppToBeFrontmost(named appName: String, timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() == appName.lowercased() {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)  // poll every 200 ms
        }
        throw LumaIntegrationError.appActivationTimeout(appName)
    }

    private static func bundleIDForAppName(_ appName: String) -> String? {
        let bundleIDByDisplayName: [String: String] = [
            "safari":               "com.apple.Safari",
            "chrome":               "com.google.Chrome",
            "google chrome":        "com.google.Chrome",
            "firefox":              "org.mozilla.firefox",
            "arc":                  "company.thebrowser.Browser",
            "finder":               "com.apple.finder",
            "notes":                "com.apple.Notes",
            "mail":                 "com.apple.mail",
            "messages":             "com.apple.MobileSMS",
            "facetime":             "com.apple.FaceTime",
            "calendar":             "com.apple.iCal",
            "reminders":            "com.apple.reminders",
            "maps":                 "com.apple.Maps",
            "photos":               "com.apple.Photos",
            "music":                "com.apple.Music",
            "podcasts":             "com.apple.podcasts",
            "tv":                   "com.apple.TV",
            "books":                "com.apple.iBooksX",
            "slack":                "com.tinyspeck.slackmacgap",
            "discord":              "com.hnc.Discord",
            "telegram":             "ru.keepcoder.Telegram",
            "zoom":                 "us.zoom.xos",
            "spotify":              "com.spotify.client",
            "xcode":                "com.apple.dt.Xcode",
            "terminal":             "com.apple.Terminal",
            "iterm":                "com.googlecode.iterm2",
            "iterm2":               "com.googlecode.iterm2",
            "vscode":               "com.microsoft.VSCode",
            "visual studio code":   "com.microsoft.VSCode",
            "figma":                "com.figma.Desktop",
            "notion":               "notion.id",
            "linear":               "com.linear",
            "system settings":      "com.apple.systempreferences",
            "system preferences":   "com.apple.systempreferences",
            "activity monitor":     "com.apple.ActivityMonitor",
        ]
        return bundleIDByDisplayName[appName.lowercased()]
    }
}

// MARK: - Browser Integration (Safari / Chrome)

/// Direct integration with web browsers.
/// Prefers AX API for reading page content — avoids vision calls when the agent
/// just needs to know what text is on screen.
enum LumaBrowserIntegration {

    /// Opens `urlString` in the default browser.
    static func openURL(_ urlString: String) throws -> String {
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw LumaIntegrationError.urlInvalid(urlString)
        }
        NSWorkspace.shared.open(url)
        return "Opened URL: \(urlString)"
    }

    /// Opens `urlString` specifically in Safari, activating it first.
    static func openURLInSafari(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString), url.scheme != nil else {
            throw LumaIntegrationError.urlInvalid(urlString)
        }
        // Activate Safari first so it becomes the frontmost app, then open the URL.
        // NSWorkspace.open(_:) uses the frontmost application as the target when no
        // explicit app is specified, so activating Safari before opening is enough.
        try await LumaAppActivator.activateApp(named: "Safari")
        NSWorkspace.shared.open(url)
        return "Opened '\(urlString)' in Safari"
    }

    /// Returns the visible text content of the frontmost browser window via the AX tree.
    /// Traverses the AXWebArea and collects AXStaticText values so the AI can read
    /// page content without a vision API call.
    /// Capped at `maxCharacters` to keep downstream prompt sizes reasonable.
    static func readPageContentViaAX(maxCharacters: Int = 3000) -> String {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return "(no frontmost application)"
        }

        let appRoot = AXUIElementCreateApplication(frontApp.processIdentifier)
        var collectedTextParts: [String] = []
        collectWebAreaText(from: appRoot, into: &collectedTextParts, depth: 0)

        let fullPageText = collectedTextParts.joined(separator: " ")
        if fullPageText.isEmpty { return "(no readable text found on page)" }

        let truncatedPageText = fullPageText.count > maxCharacters
            ? String(fullPageText.prefix(maxCharacters)) + "..."
            : fullPageText
        return truncatedPageText
    }

    // MARK: - Private AX Text Collection

    private static func collectWebAreaText(
        from element: AXUIElement,
        into results: inout [String],
        depth: Int
    ) {
        // Bail early once we have enough text — prevents walking the entire DOM
        guard depth <= 15, results.joined().count < 4000 else { return }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let elementRole = (roleRef as? String) ?? ""

        // Collect text from leaf text elements
        if elementRole == "AXStaticText" || elementRole == "AXTextField" || elementRole == "AXTextArea" {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let text = valueRef as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(text)
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectWebAreaText(from: child, into: &results, depth: depth + 1)
        }
    }
}

// MARK: - Finder Integration

/// File-system operations surfaced via Finder. Uses NSFileManager directly —
/// more reliable than simulating Finder's UI because it doesn't depend on
/// Finder's AX tree being in any particular state.
enum LumaFinderIntegration {

    /// Opens the folder at `folderPath` in a Finder window.
    static func openFolder(atFolderPath folderPath: String) throws -> String {
        let folderURL = URL(fileURLWithPath: folderPath)
        guard FileManager.default.fileExists(atPath: folderPath) else {
            throw LumaIntegrationError.elementNotFound("No folder at '\(folderPath)'")
        }
        NSWorkspace.shared.open(folderURL)
        return "Opened folder: \(folderPath)"
    }

    /// Creates a new directory at `folderPath`, including all intermediate directories.
    static func createFolder(atFolderPath folderPath: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: folderPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return "Created folder: \(folderPath)"
    }

    /// Moves the item at `sourcePath` to `destinationPath`.
    static func moveItem(fromSourcePath sourcePath: String, toDestinationPath destinationPath: String) throws -> String {
        try FileManager.default.moveItem(atPath: sourcePath, toPath: destinationPath)
        return "Moved '\(sourcePath)' to '\(destinationPath)'"
    }

    /// Copies the item at `sourcePath` to `destinationPath`.
    static func copyItem(fromSourcePath sourcePath: String, toDestinationPath destinationPath: String) throws -> String {
        try FileManager.default.copyItem(atPath: sourcePath, toPath: destinationPath)
        return "Copied '\(sourcePath)' to '\(destinationPath)'"
    }

    /// Moves the item at `itemPath` to the user's Trash.
    static func trashItem(atItemPath itemPath: String) throws -> String {
        let itemURL = URL(fileURLWithPath: itemPath)
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: itemURL, resultingItemURL: &resultingItemURL)
        return "Moved '\(itemPath)' to Trash"
    }

    /// Returns the names of all items in the directory at `directoryPath`.
    static func listDirectory(atDirectoryPath directoryPath: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directoryPath)
    }
}

// MARK: - Notes Integration

/// Creates and reads Notes via AppleScript (osascript subprocess).
/// AppleScript is the only public programmatic API for Notes — there is no
/// NSWorkspace or URL-scheme equivalent that can create notes with content.
enum LumaNotesIntegration {

    /// Creates a new note in the default Notes account with `title` and `body`.
    static func createNote(title: String, body: String) async throws -> String {
        // Escape single quotes so they don't break the AppleScript string literal
        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody  = body.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Notes"
            make new note with properties {name:"\(safeTitle)", body:"\(safeTitle)\\n\\n\(safeBody)"}
            activate
        end tell
        """
        try await runAppleScript(appleScript)
        return "Created note '\(title)'"
    }

    /// Appends `textToAppend` to the body of the first note whose name contains `titleKeyword`.
    static func appendToNote(titleKeyword: String, textToAppend: String) async throws -> String {
        let safeKeyword = titleKeyword.replacingOccurrences(of: "\"", with: "\\\"")
        let safeText    = textToAppend.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Notes"
            set matchingNote to first note whose name contains "\(safeKeyword)"
            set body of matchingNote to (body of matchingNote) & "\\n\(safeText)"
            activate
        end tell
        """
        try await runAppleScript(appleScript)
        return "Appended text to note containing '\(titleKeyword)'"
    }

    /// Returns the body text of the first note whose name contains `titleKeyword`.
    static func readNote(titleKeyword: String) async throws -> String {
        let safeKeyword = titleKeyword.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Notes"
            set matchingNote to first note whose name contains "\(safeKeyword)"
            return body of matchingNote
        end tell
        """
        return try await runAppleScript(appleScript)
    }

    // MARK: - AppleScript Runner

    @discardableResult
    static func runAppleScript(_ script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe  = Pipe()
        process.standardOutput = outputPipe
        process.standardError  = errorPipe

        try process.run()

        // Use terminationHandler + continuation so we don't block the calling thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw LumaIntegrationError.scriptFailed(
                errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - System Control Integration

/// Low-level system controls: output volume, display brightness, and Wi-Fi.
///
///   Volume:     CoreAudio `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`
///               — most reliable, works on all Macs.
///   Brightness: IOKit `IODisplayGetFloatParameter` / `IODisplaySetFloatParameter`
///               — works on Intel and most Apple Silicon; may not work on external
///               displays that use a different brightness path.
///   Wi-Fi:      `networksetup -setairportpower <interface> on/off`
///               — shell command, works without additional entitlements.
enum LumaSystemControlIntegration {

    // MARK: - Volume (CoreAudio)

    /// Returns the current default output device volume scalar (0.0–1.0).
    /// Returns 0.0 if the device cannot be queried.
    static func getOutputVolume() -> Float {
        let defaultOutputDeviceID = defaultAudioOutputDeviceID()
        guard defaultOutputDeviceID != 0 else { return 0 }

        var volumeScalar = Float32(0)
        var volumePropertySize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            defaultOutputDeviceID, &volumeAddress, 0, nil, &volumePropertySize, &volumeScalar
        )
        return volumeScalar
    }

    /// Sets the default output device volume to `normalizedVolume` (0.0–1.0, clamped).
    @discardableResult
    static func setOutputVolume(_ normalizedVolume: Float) -> String {
        let clampedVolume = max(0.0, min(1.0, normalizedVolume))
        let defaultOutputDeviceID = defaultAudioOutputDeviceID()
        guard defaultOutputDeviceID != 0 else {
            return "Volume unchanged — could not locate default output device"
        }

        var volumeScalar = Float32(clampedVolume)
        let volumePropertySize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            defaultOutputDeviceID, &volumeAddress, 0, nil, volumePropertySize, &volumeScalar
        )
        return "Set volume to \(Int(clampedVolume * 100))%"
    }

    // MARK: - Brightness (IOKit)

    /// Returns the current internal display brightness (0.0–1.0).
    /// Returns nil if the IOKit display service is not accessible (e.g. some external displays).
    static func getDisplayBrightness() -> Float? {
        var brightnessValue = Float(0)
        let readSucceeded = readBrightnessFromIOKit(&brightnessValue)
        return readSucceeded ? brightnessValue : nil
    }

    /// Sets the internal display brightness to `normalizedBrightness` (0.0–1.0, clamped).
    @discardableResult
    static func setDisplayBrightness(_ normalizedBrightness: Float) -> String {
        let clampedBrightness = max(0.0, min(1.0, normalizedBrightness))
        let writeSucceeded = writeBrightnessToIOKit(clampedBrightness)
        if writeSucceeded {
            return "Set brightness to \(Int(clampedBrightness * 100))%"
        }
        // IOKit path unavailable — log and report; agent can use clickAt on brightness slider instead
        LumaLogger.log("[LumaSystem] IOKit brightness write unavailable for this display configuration")
        return "Brightness IOKit write unavailable — try using System Settings slider"
    }

    // MARK: - Wi-Fi (networksetup)

    /// Enables or disables Wi-Fi on the system's primary Wi-Fi interface.
    /// Detects the interface name automatically; falls back to "en0" if detection fails.
    static func setWiFiEnabled(_ enabled: Bool) async -> String {
        let detectedInterfaceName = await detectWiFiInterfaceName() ?? "en0"
        let onOrOff = enabled ? "on" : "off"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-setairportpower", detectedInterfaceName, onOrOff]
        try? process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        return "Wi-Fi turned \(onOrOff) on \(detectedInterfaceName)"
    }

    // MARK: - Private CoreAudio Helper

    private static func defaultAudioOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID
        )
        return deviceID
    }

    // MARK: - Private IOKit Brightness Helpers

    private static func readBrightnessFromIOKit(_ brightnessOut: inout Float) -> Bool {
        var serviceIterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &serviceIterator
        ) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(serviceIterator) }

        let firstService = IOIteratorNext(serviceIterator)
        guard firstService != 0 else { return false }
        defer { IOObjectRelease(firstService) }

        var value = Float(0)
        // kIODisplayBrightnessKey is a String constant; cast to CFString for IODisplayGetFloatParameter
        let result = IODisplayGetFloatParameter(firstService, 0, kIODisplayBrightnessKey as CFString, &value)
        guard result == kIOReturnSuccess else { return false }
        brightnessOut = value
        return true
    }

    private static func writeBrightnessToIOKit(_ normalizedBrightness: Float) -> Bool {
        var serviceIterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &serviceIterator
        ) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(serviceIterator) }

        var wroteAtLeastOneDisplay = false
        var service = IOIteratorNext(serviceIterator)
        while service != 0 {
            let result = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, normalizedBrightness)
            if result == kIOReturnSuccess { wroteAtLeastOneDisplay = true }
            IOObjectRelease(service)
            service = IOIteratorNext(serviceIterator)
        }
        return wroteAtLeastOneDisplay
    }

    // MARK: - Private Wi-Fi Interface Detection

    /// Parses `networksetup -listallhardwareports` to find the device name for the Wi-Fi port.
    /// The output lists hardware ports and their device names line by line, e.g.:
    ///   Hardware Port: Wi-Fi
    ///   Device: en0
    private static func detectWiFiInterfaceName() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try? process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        let outputText = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        let outputLines = outputText.components(separatedBy: "\n")
        for (lineIndex, line) in outputLines.enumerated() {
            if line.contains("Wi-Fi") || line.contains("AirPort") {
                let nextLineIndex = lineIndex + 1
                if nextLineIndex < outputLines.count {
                    let deviceLine = outputLines[nextLineIndex]
                    if deviceLine.hasPrefix("Device:") {
                        return deviceLine
                            .replacingOccurrences(of: "Device:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        return nil
    }
}
