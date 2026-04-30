//
//  LumaFlowActions.swift
//  leanring-buddy
//
//  Executes individual LumaFlowActionRequests using the macOS Accessibility API
//  (AX) for element lookup and CoreGraphics events (CGEvent) for input dispatch.
//
//  All public entry points are nonisolated so the engine can call them from any
//  context; AX reads happen synchronously on the calling thread.
//

import AppKit
import ApplicationServices
import CoreServices

// MARK: - Action Executor

/// Executes a single LumaFlowActionRequest and returns a human-readable
/// observation string describing what happened.
enum LumaFlowActionExecutor {

    /// Dispatches the action to the appropriate handler and returns an observation.
    static func execute(_ action: LumaFlowActionRequest) async throws -> String {
        switch action.actionType.lowercased() {
        case "click":
            return try await clickElement(action)
        case "clickat":
            return try clickAtFraction(action)
        case "type":
            return try await typeText(action)
        case "scroll":
            return await scrollAt(action)
        case "shortcut":
            return try await executeShortcut(action)
        case "selecttext":
            return try await selectText(action)
        case "openapp":
            return try await openApp(action)
        case "drag":
            return "Drag action not yet implemented — skipping"
        case "wait":
            let seconds = max(0.1, min(action.waitSeconds ?? 1.0, 30.0))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "Waited \(String(format: "%.1f", seconds))s"
        case "ask":
            // The engine handles "ask" by surfacing to the user — executor just reports it
            return "Asking user: \(action.askQuestion ?? "(no question)")"
        case "abort":
            throw LumaFlowActionError.abortRequested(action.abortReason ?? "Claude requested abort")
        case "done":
            // "done" is handled by the engine loop before reaching the executor
            return "Step complete"
        default:
            throw LumaFlowActionError.unknownActionType(action.actionType)
        }
    }

    // MARK: - Click

    /// Clicks a UI element by label using a 2-layer fallback chain identical to the
    /// walkthrough/guide system:
    ///
    /// Layer 1: Fast synchronous AX tree search via `findAXElement` — sub-millisecond,
    ///          covers most cases where the element has a standard AX title/description.
    ///
    /// Layer 2: `LumaImageProcessingEngine.shared.findElement` — runs the full 3-sub-layer
    ///          pipeline in parallel: deep scored AX scan + MobileNet visual scan +
    ///          (when on-device confidence < 0.5) Claude Vision via APIClient.
    ///          For high-confidence AX results (confidence ≥ 0.7), the live AX frame
    ///          attribute is re-read at click time so we target the element's actual
    ///          current position rather than the scan-time snapshot.
    ///
    /// All coordinates fed to `postMouseClick` are in Quartz display coordinates
    /// (top-left origin, Y↓), matching what `.cghidEventTap` expects.
    private static func clickElement(_ action: LumaFlowActionRequest) async throws -> String {
        guard let label = action.targetElementLabel else {
            throw LumaFlowActionError.missingTarget("click requires targetElementLabel")
        }

        // ── Layer 1: fast synchronous AX search ───────────────────────────────────
        // This is the same search the old code did — cheap and instant.
        if let axElement = findAXElement(
            label: label,
            role: action.targetElementRole,
            inApp: NSWorkspace.shared.frontmostApplication
        ) {
            let frame = axElementFrame(axElement)
            if frame.width > 0, frame.height > 0 {
                let clickPoint = CGPoint(x: frame.midX, y: frame.midY)
                postMouseClick(at: clickPoint)
                LumaLogger.log("[LumaFlow] Click Layer 1 (fast AX): '\(label)' at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
                return "Clicked '\(label)' at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))"
            }
        }

        // ── Layer 2: LIPE full pipeline (deep AX + MobileNet + Claude Vision) ─────
        // Runs all sub-layers in parallel on MainActor. Layer 3 (Claude Vision via
        // APIClient) fires automatically inside LIPE when on-device confidence < 0.5.
        LumaLogger.log("[LumaFlow] Click Layer 1 miss for '\(label)' — escalating to LIPE")
        if let candidate = await LumaImageProcessingEngine.shared.findElement(
            query: label,
            appBundleID: nil,
            isMenuBar: false
        ) {
            let clickPoint = quartzClickPoint(from: candidate)
            postMouseClick(at: clickPoint)
            LumaLogger.log("[LumaFlow] Click Layer 2 (LIPE \(candidate.source), conf: \(String(format: "%.2f", candidate.confidence))): '\(label)' at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
            return "Clicked '\(label)' via LIPE (conf: \(String(format: "%.2f", candidate.confidence))) at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))"
        }

        throw LumaFlowActionError.elementNotFound("'\(label)' not found via AX or LIPE — try clickAt with coordinates from the screenshot")
    }

    /// Extracts a Quartz click point (top-left origin, Y↓) from a LIPE ElementCandidate.
    ///
    /// For high-confidence AX candidates (confidence ≥ 0.7) that carry a live `axElement`
    /// reference, we re-read `kAXFrameAttribute` at click time. This corrects cases where
    /// the element moved between the AX scan and the actual click (e.g. scroll position
    /// changed, sidebar rendered late). If the live read fails, we fall back to the
    /// scan-time `candidate.frame`.
    ///
    /// All returned points are in Quartz display coordinates (top-left origin, Y↓)
    /// matching what `CGEvent(.cghidEventTap)` expects.
    private static func quartzClickPoint(from candidate: ElementCandidate) -> CGPoint {
        if let axElement = candidate.axElement, candidate.confidence >= 0.7 {
            var frameRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, "AXFrame" as CFString, &frameRef) == .success,
               let frameValue = frameRef {
                var liveFrame = CGRect.zero
                AXValueGetValue(frameValue as! AXValue, .cgRect, &liveFrame)
                if liveFrame.width > 0, liveFrame.height > 0 {
                    // AX frame is already in Quartz coords — midX/midY is correct for CGEvent
                    return CGPoint(x: liveFrame.midX, y: liveFrame.midY)
                }
            }
        }
        // Scan-time candidate.frame is in Quartz/AX coordinates — use midpoint directly
        return CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
    }

    // MARK: - Click At Fraction

    /// Clicks at a position specified as fractions (0.0–1.0) of the main screen bounds.
    /// Use this when AX element search fails — Claude reads the coordinates from the screenshot.
    ///
    /// Coordinate system: xFraction=0.0 is the left edge, 1.0 right edge;
    /// yFraction=0.0 is the TOP edge, 1.0 is the bottom edge (matching screenshot top-left origin).
    ///
    /// Uses `CGDisplayBounds(CGMainDisplayID())` for Quartz display coordinates (top-left origin,
    /// Y↓) which is the same system CGEvent `.cghidEventTap` expects — no y-flip needed.
    private static func clickAtFraction(_ action: LumaFlowActionRequest) throws -> String {
        guard let xFraction = action.xFraction, let yFraction = action.yFraction else {
            throw LumaFlowActionError.missingTarget("clickAt requires xFraction and yFraction")
        }

        // Clamp fractions to valid range so a bad model response can't click off-screen
        let clampedX = max(0.0, min(1.0, xFraction))
        let clampedY = max(0.0, min(1.0, yFraction))

        // Quartz display bounds: origin (0,0) at top-left of primary display, Y increases downward.
        // This is the same coordinate space that CGEvent `.cghidEventTap` uses for mouse events.
        // yFraction=0 → top of screenshot → Quartz y=0 (top); yFraction=1 → bottom → Quartz y=height.
        let quartzBounds = CGDisplayBounds(CGMainDisplayID())
        let clickX = quartzBounds.minX + clampedX * quartzBounds.width
        let clickY = quartzBounds.minY + clampedY * quartzBounds.height

        let clickPoint = CGPoint(x: clickX, y: clickY)
        postMouseClick(at: clickPoint)
        LumaLogger.log("[LumaFlow] clickAt fraction (\(String(format: "%.2f", clampedX)), \(String(format: "%.2f", clampedY))) → Quartz (\(Int(clickX)), \(Int(clickY)))")
        return "Clicked at screen fraction (\(String(format: "%.2f", clampedX)), \(String(format: "%.2f", clampedY))) → pixel (\(Int(clickX)), \(Int(clickY)))"
    }

    // MARK: - Type

    /// Types text into a UI element using the same 2-layer fallback as `clickElement`:
    ///
    /// Layer 1: Fast synchronous AX search — if found, focuses via `kAXFocusedAttribute`
    ///          then types via CGEvent Unicode input.
    ///
    /// Layer 2: LIPE full pipeline — if AX+visual finds the element, focuses it via
    ///          AX attribute (when axElement is available) or by clicking at its center
    ///          (for visual-only candidates), then types.
    ///
    /// Final fallback: if no element is found by label, types into whatever element
    ///          currently has keyboard focus — useful when the model omits a target label
    ///          because the correct field is already focused.
    private static func typeText(_ action: LumaFlowActionRequest) async throws -> String {
        guard let text = action.typeText, !text.isEmpty else {
            throw LumaFlowActionError.missingTarget("type requires typeText")
        }

        let targetLabel = action.targetElementLabel
        let targetRole  = action.targetElementRole

        // ── Layer 1: fast synchronous AX search ───────────────────────────────────
        if let label = targetLabel,
           let axElement = findAXElement(
               label: label,
               role: targetRole ?? "textField",
               inApp: NSWorkspace.shared.frontmostApplication
           ) {
            focusAndTypeIntoAXElement(axElement, text: text)
            LumaLogger.log("[LumaFlow] Type Layer 1 (fast AX): '\(text.prefix(40))' → '\(label)'")
            return "Typed '\(text.prefix(60))' into '\(label)'"
        }

        // ── Layer 2: LIPE full pipeline ────────────────────────────────────────────
        if let label = targetLabel {
            LumaLogger.log("[LumaFlow] Type Layer 1 miss for '\(label)' — escalating to LIPE")
            if let candidate = await LumaImageProcessingEngine.shared.findElement(
                query: label,
                appBundleID: nil,
                isMenuBar: false
            ) {
                if let axElement = candidate.axElement {
                    // Preferred path: focus via AX attribute then type (same as Layer 1)
                    focusAndTypeIntoAXElement(axElement, text: text)
                    LumaLogger.log("[LumaFlow] Type Layer 2 (LIPE AX \(String(format: "%.2f", candidate.confidence))): '\(text.prefix(40))' → '\(label)'")
                    return "Typed '\(text.prefix(60))' into '\(label)' via LIPE AX"
                } else {
                    // Visual-only candidate: click center to focus, wait for focus to land, then type
                    let clickPoint = quartzClickPoint(from: candidate)
                    postMouseClick(at: clickPoint)
                    Thread.sleep(forTimeInterval: 0.12)   // let the app process the click + focus
                    typeViaCGEvent(text)
                    LumaLogger.log("[LumaFlow] Type Layer 2 (LIPE visual \(String(format: "%.2f", candidate.confidence))): '\(text.prefix(40))' → '\(label)' via click-focus")
                    return "Typed '\(text.prefix(60))' into '\(label)' via LIPE visual click-focus"
                }
            }
        }

        // ── Final fallback: type into whatever is currently focused ────────────────
        // Useful when the correct field is already focused (e.g. search bar after opening app)
        LumaLogger.log("[LumaFlow] Type fallback: no element found for label='\(targetLabel ?? "nil")' — typing into focused element")
        typeViaCGEvent(text)
        return "Typed '\(text.prefix(60))' into focused element"
    }

    /// Focuses an AX element and types text into it.
    /// Sets `kAXFocusedAttribute`, waits for the app to process the focus transition,
    /// then types via CGEvent Unicode input character by character.
    private static func focusAndTypeIntoAXElement(_ axElement: AXUIElement, text: String) {
        AXUIElementSetAttributeValue(axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.06)   // let the app receive the focus event
        typeViaCGEvent(text)
    }

    // MARK: - Scroll

    /// Scrolls at the target element's location. Uses the same 2-layer lookup
    /// (fast AX → LIPE) as click/type so it can find elements in Electron apps.
    /// Falls back to screen center if no element is found.
    private static func scrollAt(_ action: LumaFlowActionRequest) async -> String {
        // Default scroll point: center of the primary screen in Quartz coordinates
        let quartzBounds = CGDisplayBounds(CGMainDisplayID())
        var scrollPoint = CGPoint(x: quartzBounds.midX, y: quartzBounds.midY)

        if let label = action.targetElementLabel {
            // Layer 1: fast AX
            if let axElement = findAXElement(label: label, role: action.targetElementRole, inApp: NSWorkspace.shared.frontmostApplication) {
                let frame = axElementFrame(axElement)
                if frame.width > 0 { scrollPoint = CGPoint(x: frame.midX, y: frame.midY) }
            } else {
                // Layer 2: LIPE
                if let candidate = await LumaImageProcessingEngine.shared.findElement(query: label, appBundleID: nil, isMenuBar: false) {
                    scrollPoint = quartzClickPoint(from: candidate)
                }
            }
        }

        // Move mouse to target then post scroll wheel event (negative = scroll down)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: scrollPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -300, wheel2: 0, wheel3: 0)
        scrollEvent?.location = scrollPoint
        scrollEvent?.post(tap: .cghidEventTap)
        return "Scrolled at (\(Int(scrollPoint.x)), \(Int(scrollPoint.y)))"
    }

    // MARK: - Shortcut

    private static func executeShortcut(_ action: LumaFlowActionRequest) async throws -> String {
        guard let shortcutString = action.shortcut, !shortcutString.isEmpty else {
            throw LumaFlowActionError.missingTarget("shortcut requires a shortcut string e.g. 'Cmd+C'")
        }

        let (virtualKey, modifiers) = parseShortcutString(shortcutString)
        guard let key = virtualKey else {
            throw LumaFlowActionError.invalidShortcut("Cannot parse key from '\(shortcutString)'")
        }

        postShortcutKeyDown(virtualKey: key, flags: modifiers)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms hold
        postShortcutKeyUp(virtualKey: key, flags: modifiers)
        return "Pressed '\(shortcutString)'"
    }

    // MARK: - Select Text (Cmd+A)

    /// Clicks a target element (if given) to ensure it has focus, then sends Cmd+A.
    /// Uses the same 2-layer lookup as click/type so it works in Electron apps.
    private static func selectText(_ action: LumaFlowActionRequest) async throws -> String {
        if let label = action.targetElementLabel {
            // Layer 1: fast AX
            if let axElement = findAXElement(label: label, role: action.targetElementRole, inApp: NSWorkspace.shared.frontmostApplication) {
                let frame = axElementFrame(axElement)
                if frame.width > 0 {
                    postMouseClick(at: CGPoint(x: frame.midX, y: frame.midY))
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            } else {
                // Layer 2: LIPE
                if let candidate = await LumaImageProcessingEngine.shared.findElement(query: label, appBundleID: nil, isMenuBar: false) {
                    postMouseClick(at: quartzClickPoint(from: candidate))
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }
        postShortcutKeyDown(virtualKey: 0x00, flags: .maskCommand) // Cmd+A = kVK_ANSI_A
        try? await Task.sleep(nanoseconds: 50_000_000)
        postShortcutKeyUp(virtualKey: 0x00, flags: .maskCommand)
        return "Selected all text (Cmd+A)"
    }

    // MARK: - Open App (OS Layer)

    /// Opens an application directly via NSWorkspace — no Spotlight, no shell command.
    /// Looks up the bundle identifier from the app name, then activates or launches.
    /// This is far more reliable than using Spotlight for app launching because it
    /// goes through Launch Services at the OS level and doesn't depend on UI input timing.
    private static func openApp(_ action: LumaFlowActionRequest) async throws -> String {
        let appName = (action.targetElementLabel ?? action.typeText ?? "").trimmingCharacters(in: .whitespaces)
        guard !appName.isEmpty else {
            throw LumaFlowActionError.missingTarget("openApp requires targetElementLabel with the app name")
        }

        // 1. Check if it's already running — just activate it
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) {
            runningApp.activate(options: [.activateIgnoringOtherApps])
            return "Activated running app '\(appName)'"
        }

        // 2. Try bundle ID lookup from common app table
        if let bundleID = knownAppBundleID(for: appName) {
            let launched = NSWorkspace.shared.launchApplication(
                withBundleIdentifier: bundleID,
                options: [.default],
                additionalEventParamDescriptor: nil,
                launchIdentifier: nil
            )
            if launched {
                // Wait up to 4s for the app to become frontmost
                let deadline = Date().addingTimeInterval(4)
                while Date() < deadline {
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                return "Launched '\(appName)' via bundle ID"
            }
        }

        // 3. Fallback: open from /Applications/
        let appURL = URL(fileURLWithPath: "/Applications/\(appName).app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.open(appURL)
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s for app to load
            return "Opened '\(appName)' from /Applications/"
        }

        throw LumaFlowActionError.elementNotFound("App '\(appName)' not found on this system")
    }

    /// Lookup table of common macOS app names → bundle identifiers.
    /// Allows direct Launch Services activation without Spotlight.
    private static func knownAppBundleID(for appName: String) -> String? {
        let map: [String: String] = [
            "whatsapp":         "net.whatsapp.WhatsApp",
            "safari":           "com.apple.Safari",
            "chrome":           "com.google.Chrome",
            "google chrome":    "com.google.Chrome",
            "firefox":          "org.mozilla.firefox",
            "messages":         "com.apple.MobileSMS",
            "facetime":         "com.apple.FaceTime",
            "mail":             "com.apple.mail",
            "finder":           "com.apple.finder",
            "notes":            "com.apple.Notes",
            "calendar":         "com.apple.iCal",
            "reminders":        "com.apple.reminders",
            "maps":             "com.apple.Maps",
            "photos":           "com.apple.Photos",
            "music":            "com.apple.Music",
            "podcasts":         "com.apple.podcasts",
            "tv":               "com.apple.TV",
            "books":            "com.apple.iBooksX",
            "slack":            "com.tinyspeck.slackmacgap",
            "telegram":         "ru.keepcoder.Telegram",
            "discord":          "com.hnc.Discord",
            "zoom":             "us.zoom.xos",
            "spotify":          "com.spotify.client",
            "xcode":            "com.apple.dt.Xcode",
            "terminal":         "com.apple.Terminal",
            "iterm":            "com.googlecode.iterm2",
            "iterm2":           "com.googlecode.iterm2",
            "vscode":           "com.microsoft.VSCode",
            "visual studio code": "com.microsoft.VSCode",
            "figma":            "com.figma.Desktop",
            "notion":           "notion.id",
            "linear":           "com.linear",
            "arc":              "company.thebrowser.Browser",
            "system preferences":   "com.apple.systempreferences",
            "system settings":      "com.apple.systempreferences",
            "activity monitor":     "com.apple.ActivityMonitor",
            "screen recording":     "com.apple.Screenshot",
        ]
        return map[appName.lowercased()]
    }

    // MARK: - AX Element Search

    /// Recursively searches the AX tree of `app` for an element whose title, description,
    /// placeholder, or value contains `label` and (optionally) matches `role`.
    static func findAXElement(
        label: String,
        role: String?,
        inApp app: NSRunningApplication?
    ) -> AXUIElement? {
        guard let app else { return nil }
        let appRoot = AXUIElementCreateApplication(app.processIdentifier)
        return searchAXTree(
            element: appRoot,
            targetLabel: label.lowercased(),
            targetRole: role?.lowercased(),
            depth: 0,
            maxDepth: 20
        )
    }

    private static func searchAXTree(
        element: AXUIElement,
        targetLabel: String,
        targetRole: String?,
        depth: Int,
        maxDepth: Int
    ) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }

        // Role check — AX roles are prefixed with "AX" (e.g. "AXButton"), so we
        // normalize by stripping the prefix before comparing against the caller's role.
        if let targetRole, !targetRole.isEmpty {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let elementRole = ((roleRef as? String) ?? "").lowercased()
            let normalizedRole = elementRole.hasPrefix("ax") ? String(elementRole.dropFirst(2)) : elementRole
            // Only skip elements that don't match AND aren't likely containers
            let isContainer = ["axgroup", "axscrollarea", "axwebarea", "axsplitgroup",
                               "axoutline", "axtoolbar", "axscrollview"].contains(elementRole)
            if !isContainer && !normalizedRole.contains(targetRole) && !targetRole.contains(normalizedRole) {
                return searchChildren(element: element, targetLabel: targetLabel, targetRole: targetRole, depth: depth, maxDepth: maxDepth)
            }
        }

        // Label matching — check title, description, placeholder, value
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute] as [CFString] {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute, &valueRef)
            if let str = valueRef as? String, str.lowercased().contains(targetLabel) {
                return element
            }
        }

        return searchChildren(element: element, targetLabel: targetLabel, targetRole: targetRole, depth: depth, maxDepth: maxDepth)
    }

    private static func searchChildren(
        element: AXUIElement,
        targetLabel: String,
        targetRole: String?,
        depth: Int,
        maxDepth: Int
    ) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = searchAXTree(element: child, targetLabel: targetLabel, targetRole: targetRole, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Returns the CGRect frame of an AX element in screen coordinates (CG top-left origin).
    /// Increasing depth to 20 ensures we can reach elements in Electron/web-wrapped apps
    /// (WhatsApp, Slack, Discord) whose AX trees are deeply nested via AXWebArea.
    static func axElementFrame(_ element: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var position = CGPoint.zero
        var size = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &position) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: position, size: size)
    }

    // MARK: - CGEvent Helpers

    private static func postMouseClick(at point: CGPoint) {
        // Mouse events use cghidEventTap to move the actual visible cursor on screen
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func postShortcutKeyDown(virtualKey: CGKeyCode, flags: CGEventFlags) {
        // cgSessionEventTap delivers keyboard events to the focused window at the session level,
        // which works for system UIs (dialogs, Spotlight, etc.) unlike cghidEventTap.
        let source = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        event?.flags = flags
        event?.post(tap: .cgSessionEventTap)
    }

    private static func postShortcutKeyUp(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        event?.flags = flags
        event?.post(tap: .cgSessionEventTap)
    }

    /// Types text character-by-character via CGEvent Unicode keyboard input.
    /// Uses cgSessionEventTap so keystrokes reach any focused window including
    /// system dialogs and web-wrapped apps (WhatsApp, Slack, etc.).
    private static func typeViaCGEvent(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            var utf16: [UniChar] = character.utf16.map { $0 }

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyDown?.post(tap: .cgSessionEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyUp?.post(tap: .cgSessionEventTap)

            // Small delay between characters to avoid dropped keystrokes in fast apps
            Thread.sleep(forTimeInterval: scalar.value > 127 ? 0.008 : 0.004)
        }
    }

    // MARK: - Shortcut String Parser

    /// Parses a shortcut string like "Cmd+Shift+T" into (virtualKey, CGEventFlags).
    private static func parseShortcutString(_ shortcut: String) -> (CGKeyCode?, CGEventFlags) {
        let parts = shortcut.components(separatedBy: "+")
        var modifiers: CGEventFlags = []
        var keyName = ""

        for part in parts {
            switch part.lowercased().trimmingCharacters(in: .whitespaces) {
            case "cmd", "command":          modifiers.insert(.maskCommand)
            case "shift":                   modifiers.insert(.maskShift)
            case "opt", "option", "alt":    modifiers.insert(.maskAlternate)
            case "ctrl", "control":         modifiers.insert(.maskControl)
            default:                        keyName = part
            }
        }

        return (virtualKeyCode(for: keyName), modifiers)
    }

    private static func virtualKeyCode(for character: String) -> CGKeyCode? {
        // Subset covering common shortcuts. Key codes are hardware-layout constants.
        let map: [String: CGKeyCode] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
            "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
            "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
            "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
            "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
            "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
            "tab": 0x30, "space": 0x31, "backspace": 0x33, "delete": 0x33,
            "escape": 0x35, "esc": 0x35, "return": 0x24, "enter": 0x24,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
            "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        ]
        return map[character.lowercased()]
    }
}

// MARK: - Errors

enum LumaFlowActionError: LocalizedError {
    case missingTarget(String)
    case elementNotFound(String)
    case invalidShortcut(String)
    case unknownActionType(String)
    case abortRequested(String)

    var errorDescription: String? {
        switch self {
        case .missingTarget(let m):    return "Missing target: \(m)"
        case .elementNotFound(let m):  return "Element not found: \(m)"
        case .invalidShortcut(let m):  return "Invalid shortcut: \(m)"
        case .unknownActionType(let t): return "Unknown action type: \(t)"
        case .abortRequested(let r):   return "Aborted: \(r)"
        }
    }
}
