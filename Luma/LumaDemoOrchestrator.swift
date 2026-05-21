//
//  LumaDemoOrchestrator.swift
//  Luma
//
//  Drives the post-permission interactive demo sequence:
//  1. Capture the frontmost app's AX tree for 2-3 visible named interactive elements
//  2. Narrate what Luma can see and point the cursor at each element
//  3. Invite the user to give a command
//  4. Execute the command through the normal pipeline
//  5. Mark demo complete
//
//  Owned by OnboardingDemoStep via @StateObject. The demo Task is cancelled
//  automatically if the view disappears (user navigates back or skips).
//

import AppKit
import Foundation

@MainActor
final class LumaDemoOrchestrator: ObservableObject {

    enum DemoPhase {
        case scanning
        case narrating(elementName: String)
        case inviting
        case executing
        case complete
    }

    @Published private(set) var phase: DemoPhase = .scanning
    @Published private(set) var spokenText: String = ""

    private weak var companionManager: CompanionManager?
    private var demoTask: Task<Void, Never>?

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        demoTask = Task { [weak self] in
            await self?.runDemoSequence(companionManager: companionManager)
        }
    }

    func cancel() {
        demoTask?.cancel()
        demoTask = nil
    }

    /// Called by OnboardingDemoStep after the user submits a command.
    /// Transitions the phase to executing so the UI updates.
    func markExecuting() {
        phase = .executing
    }

    /// Called by OnboardingDemoStep after the command pipeline completes.
    func markComplete() {
        phase = .complete
    }

    // MARK: - Demo Sequence

    private func runDemoSequence(companionManager: CompanionManager) async {
        guard !Task.isCancelled else { return }

        phase = .scanning
        let demoElements = await scanVisibleElements()

        guard !Task.isCancelled else { return }

        if demoElements.isEmpty {
            let fallbackText = "I can see your screen. I can help you navigate apps, open files, answer questions, and more. Try giving me a command."
            await speak(fallbackText, via: companionManager)
        } else {
            // Narrate the first element with the app name, then each subsequent element
            for (index, element) in demoElements.enumerated() {
                guard !Task.isCancelled else { return }
                phase = .narrating(elementName: element.name)

                let narration: String
                if index == 0 {
                    let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app"
                    narration = "I can see \(appName) is open. I can see the \(element.name)."
                } else {
                    narration = "I can also see the \(element.name)."
                }

                await speak(narration, via: companionManager)

                // Point the Luma cursor at the element using the existing CursorGuide notification.
                // Target point must be wrapped in NSValue (AppKit screen coordinates).
                NotificationCenter.default.post(
                    name: CursorGuide.pointAtNotificationName,
                    object: nil,
                    userInfo: [
                        CursorGuide.targetPointUserInfoKey: NSValue(point: element.screenPoint),
                        CursorGuide.bubbleTextUserInfoKey: element.name
                    ]
                )

                // Brief pause between elements so the user can follow along
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        guard !Task.isCancelled else { return }

        // Invite the user to give a real command
        phase = .inviting
        let inviteText = "Try giving me a command — hold Control and Option and speak, or type below."
        await speak(inviteText, via: companionManager)
    }

    /// Scans the frontmost app's AX tree for up to 3 named interactive elements.
    /// Returns an empty array if AX is unavailable or the app has no named interactive children.
    private func scanVisibleElements() async -> [DemoElement] {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var focusedWindowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        guard let focusedWindowRef else { return [] }
        let focusedWindow = focusedWindowRef as! AXUIElement

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindow, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return [] }

        // Interactive element roles that are useful to point at during a demo
        let interactiveRoles: Set<String> = ["AXButton", "AXTextField", "AXList", "AXMenuItem", "AXLink", "AXCheckBox"]

        var results: [DemoElement] = []
        for child in children.prefix(20) {
            guard results.count < 3 else { break }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, !title.isEmpty else { continue }

            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            guard interactiveRoles.contains(role) else { continue }

            var frameRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXFrameAttribute as CFString, &frameRef)
            guard let frameRef else { continue }
            guard let frame = extractCGRect(from: frameRef) else { continue }

            // Convert AX (Quartz, top-left origin) to AppKit (bottom-left origin) for CursorGuide
            guard let mainScreen = NSScreen.main else { continue }
            let appKitY = mainScreen.frame.height - frame.midY
            let screenPoint = CGPoint(x: frame.midX, y: appKitY)

            results.append(DemoElement(name: title, role: role, screenPoint: screenPoint))
        }

        return results
    }

    private func extractCGRect(from value: CFTypeRef) -> CGRect? {
        var rect = CGRect.zero
        // AX frame values are stored as AXValue (kAXValueCGRectType)
        let axValue = value as! AXValue
        let success = AXValueGetValue(axValue, .cgRect, &rect)
        return success ? rect : nil
    }

    private func speak(_ text: String, via companionManager: CompanionManager) async {
        spokenText = text
        companionManager.speakDemoText(text)
        // Wait based on word count — approximate TTS duration
        let wordCount = text.split(separator: " ").count
        let estimatedDuration = max(2.0, Double(wordCount) * 0.35)
        try? await Task.sleep(nanoseconds: UInt64(estimatedDuration * 1_000_000_000))
    }

    // MARK: - Model

    struct DemoElement {
        let name: String
        let role: String
        let screenPoint: CGPoint
    }
}
