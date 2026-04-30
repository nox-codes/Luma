//
//  LumaImageProcessingEngine.swift
//  leanring-buddy
//
//  Combines Accessibility API + screenshot analysis to locate UI elements with
//  high confidence. Both sources run in parallel and their results are cross-validated:
//  when they agree (frames overlap), confidence is boosted and source is .both.
//
//  This is the single authority for "find element X on screen" in the walkthrough
//  system. CursorGuide.pointAtElement remains available for one-shot pointing from
//  the CompanionManager voice flow.
//

import AppKit
import ApplicationServices
import Foundation
import ImageIO

// MARK: - SourceType

/// Which detection path(s) found a given element candidate.
enum SourceType: Equatable {
    /// Found only through the Accessibility API.
    case accessibility
    /// Found only through screenshot/visual analysis (MobileNet or AI).
    case visual
    /// Confirmed by both Accessibility API and visual analysis — highest reliability.
    case both
}

// MARK: - ElementCandidate

/// A UI element candidate returned by LumaImageProcessingEngine.
struct ElementCandidate: Identifiable {
    let id: UUID = UUID()
    let name: String
    let role: String
    /// Frame in Quartz/AX coordinates (top-left origin, Y↓). From Accessibility API.
    /// Use LumaImageProcessingEngine.toScreenPoint(_:) to convert to AppKit before using.
    let frame: CGRect
    /// Frame from screenshot analysis in Quartz/AX coordinates, if available.
    let visualFrame: CGRect?
    /// 0.0–1.0 confidence in this candidate being the correct element.
    let confidence: Double
    /// Which source(s) found this candidate.
    let source: SourceType
    let appBundleID: String?
    let isMenuBar: Bool
    /// Live AX element reference. Present for accessibility and both sources.
    /// Used by pointCursor to re-read kAXFrameAttribute at point time so the cursor
    /// targets the element's actual current position rather than the scan-time snapshot.
    let axElement: AXUIElement?
}

// MARK: - LumaImageProcessingEngine

/// Central element-finding authority for the walkthrough system.
/// Runs AX scan and visual scan in parallel, cross-validates results, and
/// returns the highest-confidence candidate above a minimum threshold.
@MainActor
final class LumaImageProcessingEngine {
    static let shared = LumaImageProcessingEngine()
    private init() {}

    /// Minimum confidence required to return a candidate. Below this, nil is returned.
    private let minimumConfidenceThreshold: Double = 0.3

    /// Frame overlap fraction required to merge an AX candidate with a visual candidate.
    private let crossValidationOverlapThreshold: Double = 0.6

    // MARK: - Public API

    /// Finds the best matching element for `query` using both AX and visual scanning.
    ///
    /// - Parameters:
    ///   - query: The visible label or name of the target UI element.
    ///   - appBundleID: The app the element lives in, or nil for the frontmost app.
    ///   - isMenuBar: True if the element is expected to be in the macOS menu bar.
    /// - Returns: The highest-confidence candidate, or nil if nothing meets the threshold.
    func findElement(
        query: String,
        appBundleID: String?,
        isMenuBar: Bool
    ) async -> ElementCandidate? {

        // Run both scans in parallel — AX is fast, visual takes a screenshot + optional ML
        async let axCandidates = scanAccessibilityTree(query: query, appBundleID: appBundleID, isMenuBar: isMenuBar)
        async let visualCandidates = scanVisual(query: query)

        let (axResults, visualResults) = await (axCandidates, visualCandidates)

        let mergedCandidates = crossValidate(axCandidates: axResults, visualCandidates: visualResults)

        let bestCandidate = mergedCandidates
            .sorted { $0.confidence > $1.confidence }
            .first(where: { $0.confidence >= minimumConfidenceThreshold })

        if let best = bestCandidate {
            LumaLogger.log("[LIPE] Best match: '\(best.name)' confidence: \(String(format: "%.2f", best.confidence)) source: \(best.source)")
        } else {
            LumaLogger.log("[LIPE] No candidate above threshold \(minimumConfidenceThreshold) for query '\(query)'")
        }

        return bestCandidate
    }

    // MARK: - Coordinate Validation Gate

    /// Validates that `point` has visible visual content (via MobileNetV2 presence check)
    /// before animating the cursor. Calls `move` when content is confirmed.
    /// If MobileNetV2 finds a blank region at the coordinate, calls
    /// `requestCoordinateRetry(for:)` instead of moving the cursor.
    ///
    /// MobileNetV2 is used as a PRESENCE CHECK ONLY — it does not match element names.
    /// A top ImageNet confidence > 0.1 (meaning something is visually there, not blank)
    /// is sufficient to pass. The Accessibility API owns all element name matching.
    ///
    /// - Parameters:
    ///   - point: The screen coordinate (AppKit, bottom-left origin) to validate.
    ///   - screenshot: The current screen capture used for region presence check.
    ///   - move: Closure to invoke when visual content is confirmed at the coordinate.
    func validateAndMove(to point: CGPoint, screenshot: NSImage, then move: @escaping () -> Void) {
        guard let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Cannot convert screenshot — pass through rather than blocking cursor movement.
            move()
            return
        }

        Task {
            let hasContent = await LumaMobileNetDetector.shared.coordinateHasContent(at: point, in: cgImage)
            if hasContent {
                move()
            } else {
                LumaLogger.log("[LIPE] Coordinate (\(point.x), \(point.y)) has no visible content — skipping cursor move")
                self.requestCoordinateRetry(for: point)
            }
        }
    }

    /// Called when MobileNet rejects an AI-returned coordinate.
    /// LIPE does not own the Claude API — it logs the rejection and returns so the
    /// WalkthroughEngine's nudge timer and periodic AI validation can handle recovery
    /// without this layer attempting a redundant API call.
    private func requestCoordinateRetry(for rejectedPoint: CGPoint) {
        LumaLogger.log("[LIPE] Coordinate retry requested for (\(rejectedPoint.x), \(rejectedPoint.y)) — deferring to WalkthroughEngine nudge cycle")
        // The WalkthroughEngine nudge timer will re-point the cursor on its next tick.
        // No action needed here — not calling move() is the correct no-op.
    }

    /// Notifies the overlay to animate the Luma cursor to `candidate.frame`.
    /// Luma NEVER moves the OS cursor — only the blue overlay cursor animates.
    /// `bubbleText` is shown in the small speech bubble next to the cursor when it arrives.
    ///
    /// When the candidate came from the AX path (source: .accessibility or .both) and
    /// confidence is high, we re-read kAXFrameAttribute from the live element instead of
    /// using the scan-time snapshot in candidate.frame. This corrects cases where the
    /// element moved between the tree scan and the cursor animation (e.g. sidebar items
    /// that render late), which is the root cause of wrong cursor target coordinates.
    func pointCursor(at candidate: ElementCandidate, bubbleText: String? = nil) {
        let screenPoint: CGPoint

        let shouldUseLiveAXFrame = (candidate.source == .accessibility || candidate.source == .both)
            && candidate.confidence >= 0.8
            && candidate.axElement != nil

        if shouldUseLiveAXFrame, let liveElement = candidate.axElement {
            var freshFrame = CGRect.zero
            var frameRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(liveElement, "AXFrame" as CFString, &frameRef) == .success,
               let frameValue = frameRef {
                AXValueGetValue(frameValue as! AXValue, .cgRect, &freshFrame)
            }

            if freshFrame.width > 0 && freshFrame.height > 0 {
                let mainScreenHeight = NSScreen.main?.frame.height ?? 0
                let centerX = freshFrame.midX
                let centerY = mainScreenHeight - freshFrame.origin.y - freshFrame.size.height / 2
                LumaLogger.log("[LIPE] Corrected center: (\(centerX), \(centerY)) from AX frame (\(freshFrame.origin.x), \(freshFrame.origin.y), \(freshFrame.width), \(freshFrame.height))")
                screenPoint = CGPoint(x: centerX, y: centerY)
            } else {
                // Live read returned an empty frame — fall back to the scan-time snapshot
                screenPoint = toScreenPoint(candidate.frame)
            }
        } else {
            screenPoint = toScreenPoint(candidate.frame)
        }

        LumaLogger.log("[LIPE] Pointing Luma cursor to \(screenPoint) for '\(candidate.name)'")

        var userInfo: [String: Any] = [
            CursorGuide.targetPointUserInfoKey: NSValue(point: screenPoint)
        ]
        if let text = bubbleText {
            userInfo[CursorGuide.bubbleTextUserInfoKey] = text
        }
        NotificationCenter.default.post(
            name: CursorGuide.pointAtNotificationName,
            object: nil,
            userInfo: userInfo
        )
    }

    // MARK: - Step 1: Accessibility API Scan

    /// Scans the target app's AX tree (or menu bar) and returns the top 5 scored candidates.
    func scanAccessibilityTree(
        query: String,
        appBundleID: String?,
        isMenuBar: Bool
    ) async -> [ElementCandidate] {
        var collectedElements: [CollectedAXElement] = []

        if isMenuBar {
            // Menu bar scan: frontmost app menu bar + ControlCenter + SystemUIServer
            collectMenuBarElements(into: &collectedElements)
        } else {
            // App scan: specific app or frontmost
            let rootPID: pid_t?
            if let bundleID = appBundleID,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                rootPID = app.processIdentifier
            } else {
                rootPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            }

            if let pid = rootPID {
                let appElement = AXUIElementCreateApplication(pid)
                collectAXElements(from: appElement, into: &collectedElements, depth: 0, maxDepth: 12)
            }

            // When the query targets an app that is NOT the frontmost app, the user
            // likely wants to click its Dock icon. Scan com.apple.dock so AXDockItem
            // candidates are included alongside any AXMenuBarItem candidates that the
            // frontmost app's tree may contain with the same name.
            let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let queryMatchesFrontmostApp = frontmostAppName.lowercased() == query.lowercased()
                || frontmostAppName.lowercased().contains(query.lowercased())
                || query.lowercased().contains(frontmostAppName.lowercased())

            if !queryMatchesFrontmostApp,
               let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
                // Depth 4 is enough to reach AXDockItem nodes inside the Dock's AX tree
                collectAXElements(from: dockElement, into: &collectedElements, depth: 0, maxDepth: 4)
            }
        }

        var scored = collectedElements
            .map { element -> (element: CollectedAXElement, score: Int) in
                (element: element, score: scoreElement(element, query: query))
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        // If the scored results contain any AXDockItem candidate, penalise competing
        // AXMenuBarItem candidates that share the same label by −50 so the Dock icon
        // wins when the user intends to launch or switch to an app via the Dock.
        let dockItemLabels = Set(
            scored
                .filter { $0.element.role == "AXDockItem" }
                .map { $0.element.title.lowercased() }
        )
        if !dockItemLabels.isEmpty {
            scored = scored.map { item in
                guard item.element.role == "AXMenuBarItem",
                      dockItemLabels.contains(item.element.title.lowercased()) else {
                    return item
                }
                return (element: item.element, score: max(1, item.score - 50))
            }
            .sorted { $0.score > $1.score }
        }

        let topScored = scored.prefix(5)

        LumaLogger.log("[LIPE] AX scan '\(query)': \(topScored.count) candidate(s) of \(collectedElements.count) total")
        for candidate in topScored {
            LumaLogger.log("[LIPE]   AX '\(candidate.element.title)' role=\(candidate.element.role) score=\(candidate.score)")
        }

        return topScored.map { item in
            ElementCandidate(
                name: item.element.title,
                role: item.element.role,
                frame: item.element.axFrame,
                visualFrame: nil,
                confidence: Double(item.score) / 100.0,
                source: .accessibility,
                appBundleID: appBundleID,
                isMenuBar: isMenuBar,
                axElement: item.element.element
            )
        }
    }

    // MARK: - Step 2: Visual / Screenshot Scan

    /// Captures the screen and runs the on-device detection pipeline (Layers 1+2).
    /// Falls back to Layer 3 (Claude Vision via APIClient) when no on-device result
    /// has confidence ≥ 0.5. When MobileNetDetector has no model, Layer 2 is skipped
    /// but Layer 1 Vision requests still run and Layer 3 still fires if needed.
    func scanVisual(query: String) async -> [ElementCandidate] {
        // Capture via ScreenCaptureKit (replaces the deprecated CGWindowListCreateImage).
        // CompanionScreenCaptureUtility returns JPEG data; we convert it to a CGImage
        // for the on-device detector. If capture fails we return empty — the AX path
        // still runs in parallel and is unaffected.
        guard let screenCapture = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first,
              let imageSource = CGImageSourceCreateWithData(screenCapture.imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return []
        }

        let screenSize = CGSize(
            width: screenCapture.displayWidthInPoints,
            height: screenCapture.displayHeightInPoints
        )

        // Layers 1+2: on-device Vision text detection + MobileNet crop validation.
        // searchQuery is threaded through so Layer 1 text matching is query-aware.
        let detectionResults = await LumaOnDeviceAI.shared.detectElements(
            in: cgImage,
            screenSize: screenSize,
            searchQuery: query
        )

        // Score and cap visual-only candidates at 0.4 confidence (visual results without AX
        // confirmation are less precise — the cap prevents them dominating over AX results
        // but still lets cross-validation boost them when AX agrees).
        let scoredVisualCandidates: [ElementCandidate] = Array(detectionResults
            .filter { $0.confidence > 0.3 }
            .map { result -> ElementCandidate in
                let labelMatchScore = scoreLabel(result.label, against: query)
                let combinedConfidence = min((Double(labelMatchScore) / 100.0) * result.confidence, 0.4)
                return ElementCandidate(
                    name: result.label,
                    role: "AXUnknown",
                    frame: result.screenFrame,
                    visualFrame: result.screenFrame,
                    confidence: combinedConfidence,
                    source: .visual,
                    appBundleID: nil,
                    isMenuBar: false,
                    axElement: nil
                )
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5))

        // Fire Layer 3 when no on-device result has sufficient confidence.
        // We check the raw detection confidence (before the 0.4 visual-only cap) so we do NOT
        // fire Layer 3 when Layer 1+2 found a high-confidence match that was merely capped.
        // Example: Layer 1 returns confidence=0.85 → capped to 0.4 in scoredVisualCandidates,
        // but bestOnDeviceConfidence=0.85 ≥ 0.5, so Layer 3 correctly does NOT fire.
        let bestOnDeviceConfidence = detectionResults.map { $0.confidence }.max() ?? 0.0
        if bestOnDeviceConfidence < 0.5 {
            if let layer3Candidate = await detectElementViaAPIClient(
                screenshotData: screenCapture.imageData,
                screenCapture: screenCapture,
                searchQuery: query
            ) {
                // Prepend Layer 3 result so crossValidate can merge it with an overlapping AX
                // candidate. If AX and Layer 3 agree, the merged result inherits the real AX
                // frame (replacing the estimated adaptive box) and gets the +0.3 confidence boost.
                return [layer3Candidate] + Array(scoredVisualCandidates)
            }
        }

        return Array(scoredVisualCandidates)
    }

    // MARK: - Layer 3: Claude Vision API Fallback

    /// Sends the screenshot to Claude via APIClient and parses a [POINT:x,y:label] coordinate tag.
    /// Only called from scanVisual when both on-device layers (1+2) return confidence < 0.5.
    ///
    /// Mirrors CursorGuide.pointAtElementViaAIScreenshot but returns an ElementCandidate
    /// for cross-validation rather than posting a notification for cursor movement.
    private func detectElementViaAPIClient(
        screenshotData: Data,
        screenCapture: CompanionScreenCapture,
        searchQuery: String
    ) async -> ElementCandidate? {
        let screenshotDimensionDescription = "\(screenCapture.screenshotWidthInPixels)×\(screenCapture.screenshotHeightInPixels)"

        let elementLocationSystemPrompt = """
        You are a macOS screen analyzer that locates UI elements.
        The screenshot is \(screenshotDimensionDescription) pixels.

        When asked to find a UI element, respond with ONLY a [POINT:x,y:label] tag — nothing else.
        - x and y are integer pixel coordinates of the CENTER of the target element (top-left origin, 0,0 = top-left corner)
        - label is a 1-3 word description of the element
        - If the element is not visible: [POINT:none]
        """

        guard let (apiResponse, _) = try? await APIClient.shared.analyzeImage(
            images: [(data: screenshotData, label: "user's screen")],
            systemPrompt: elementLocationSystemPrompt,
            conversationHistory: [],
            userPrompt: "Find the UI element named \"\(searchQuery)\" and return its pixel coordinates.",
            maxOutputTokens: 32
        ) else {
            LumaLogger.log("[LIPE] Layer 3: APIClient call failed for '\(searchQuery)'")
            return nil
        }

        LumaLogger.log("[LIPE] Layer 3 response for '\(searchQuery)': \(apiResponse)")

        guard let pixelCoordinate = Self.parsePointTagFromAPIResponse(apiResponse) else {
            LumaLogger.log("[LIPE] Layer 3: no valid [POINT:x,y] tag in response for '\(searchQuery)'")
            return nil
        }

        // Scale from screenshot pixel coordinates (top-left origin) to Quartz screen coordinates
        // (also top-left origin in this context — matching how AX frames are stored in LIPE).
        let quartzX = pixelCoordinate.x * (CGFloat(screenCapture.displayWidthInPoints)  / CGFloat(screenCapture.screenshotWidthInPixels))
        let quartzY = pixelCoordinate.y * (CGFloat(screenCapture.displayHeightInPoints) / CGFloat(screenCapture.screenshotHeightInPixels))

        let estimatedBoxSize = Self.adaptiveBoundingBoxSize(forSearchQuery: searchQuery)
        let estimatedScreenFrame = CGRect(
            x: quartzX - estimatedBoxSize.width  / 2,
            y: quartzY - estimatedBoxSize.height / 2,
            width:  estimatedBoxSize.width,
            height: estimatedBoxSize.height
        )

        LumaLogger.log("[LIPE] Layer 3: '\(searchQuery)' at Quartz (\(Int(quartzX)), \(Int(quartzY))) — \(Int(estimatedBoxSize.width))×\(Int(estimatedBoxSize.height))pt estimated box")

        // confidence=0.55: slightly above the Layer 3 trigger threshold (0.5) so this candidate
        // participates in crossValidate. If an AX candidate overlaps the estimated box, the merged
        // result inherits the real AX frame and receives the +0.3 confidence boost.
        return ElementCandidate(
            name: searchQuery,
            role: "AXUnknown",
            frame: estimatedScreenFrame,
            visualFrame: estimatedScreenFrame,
            confidence: 0.55,
            source: .visual,
            appBundleID: nil,
            isMenuBar: false,
            axElement: nil
        )
    }

    /// Parses a `[POINT:x,y]` or `[POINT:x,y:label]` tag from an API response string.
    /// Returns `nil` when the response is `[POINT:none]` or contains no valid coordinate tag.
    ///
    /// Static so unit tests can call it directly without needing the @MainActor shared instance.
    static func parsePointTagFromAPIResponse(_ responseText: String) -> CGPoint? {
        // Matches [POINT:x,y] with optional :label suffix. Does not match [POINT:none].
        // Group 1 = x coordinate digits, Group 2 = y coordinate digits.
        let pointTagPattern = #"\[POINT:(\d+)\s*,\s*(\d+)(?::[^\]]*)?\]"#

        guard let regex = try? NSRegularExpression(pattern: pointTagPattern),
              let match = regex.firstMatch(
                  in: responseText,
                  range: NSRange(responseText.startIndex..., in: responseText)
              ),
              match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let parsedX = Double(responseText[xRange]),
              let parsedY = Double(responseText[yRange])
        else { return nil }

        return CGPoint(x: parsedX, y: parsedY)
    }

    /// Returns the estimated bounding box size for a Layer 3 AI-located element.
    ///
    /// The AI returns a center point, not a box. Box size is estimated from query length:
    /// - ≤ 2 chars (e.g. "R", "V"): 24×24 pt — icon or keyboard shortcut key target
    /// - > 2 chars (word or phrase): 60×30 pt — standard button or label
    ///
    /// If cross-validation finds an overlapping AX candidate, the merged result's `frame`
    /// is replaced with the real AX frame — the estimated box is only used for the overlap check.
    ///
    /// Static so unit tests can call it directly without needing the @MainActor shared instance.
    static func adaptiveBoundingBoxSize(forSearchQuery searchQuery: String) -> CGSize {
        if searchQuery.count <= 2 {
            return CGSize(width: 24, height: 24)
        }
        return CGSize(width: 60, height: 30)
    }

    // MARK: - Step 3: Cross Validation

    /// Merges AX candidates with visual candidates. When an AX frame and visual frame
    /// overlap by more than `crossValidationOverlapThreshold`, they are merged into a
    /// single .both candidate with a 0.3 confidence bonus.
    private func crossValidate(
        axCandidates: [ElementCandidate],
        visualCandidates: [ElementCandidate]
    ) -> [ElementCandidate] {
        var results: [ElementCandidate] = []
        var matchedVisualIndices: Set<Int> = []

        for axCandidate in axCandidates {
            var bestVisualMatch: (index: Int, overlap: Double)?

            for (visualIndex, visualCandidate) in visualCandidates.enumerated() {
                let overlap = frameOverlapFraction(axCandidate.frame, visualCandidate.frame)
                if overlap > crossValidationOverlapThreshold {
                    if bestVisualMatch == nil || overlap > bestVisualMatch!.overlap {
                        bestVisualMatch = (index: visualIndex, overlap: overlap)
                    }
                }
            }

            if let match = bestVisualMatch {
                // Both sources agree — merge and boost confidence
                matchedVisualIndices.insert(match.index)
                let mergedConfidence = min(axCandidate.confidence + 0.3, 1.0)
                let merged = ElementCandidate(
                    name: axCandidate.name,
                    role: axCandidate.role,
                    frame: axCandidate.frame,
                    visualFrame: visualCandidates[match.index].visualFrame,
                    confidence: mergedConfidence,
                    source: .both,
                    appBundleID: axCandidate.appBundleID,
                    isMenuBar: axCandidate.isMenuBar,
                    axElement: axCandidate.axElement
                )
                results.append(merged)
            } else {
                // AX only — use as-is
                results.append(axCandidate)
            }
        }

        // Add unmatched visual candidates (they remain visual-only)
        for (index, visualCandidate) in visualCandidates.enumerated() {
            if !matchedVisualIndices.contains(index) {
                results.append(visualCandidate)
            }
        }

        return results
    }

    // MARK: - Step 4: Coordinate Conversion

    /// Converts an AX frame (Quartz coordinates, top-left origin, Y↓) to an AppKit screen
    /// point (bottom-left origin, Y↑) at the element's center. Ready to pass to pointCursor(at:).
    func toScreenPoint(_ axFrame: CGRect) -> CGPoint {
        // AX/Quartz coordinate system: origin at the top-left of the MAIN display, Y increases downward.
        // AppKit coordinate system: origin at the bottom-left of the MAIN display, Y increases upward.
        //
        // Correct formula for the element center:
        //   appKitY = screenHeight - axFrame.origin.y - axFrame.size.height
        //
        // Why: axFrame.origin.y is the Quartz top edge. Adding size.height reaches the Quartz
        // bottom edge (origin.y + height = maxY). screenHeight - maxY gives the AppKit Y of
        // that bottom edge, which is the correct visual center anchor for cursor placement.
        //
        // The previously used (screenHeight - midY) was off by half the element height,
        // causing the cursor to land above the element rather than on it.
        let mainScreenHeight = NSScreen.main?.frame.height ?? 0
        let appKitY = mainScreenHeight - axFrame.origin.y - (axFrame.size.height / 2)
        return CGPoint(x: axFrame.midX, y: appKitY)
    }

    // MARK: - Step 5: Menu Bar Scan

    /// Scans the menu bar hierarchy (frontmost app menu bar + ControlCenter + SystemUIServer).
    func scanMenuBar(query: String) async -> [ElementCandidate] {
        var collectedElements: [CollectedAXElement] = []
        collectMenuBarElements(into: &collectedElements)

        let scored = collectedElements
            .map { (element: $0, score: scoreElement($0, query: query)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(5)

        return scored.map { item in
            ElementCandidate(
                name: item.element.title,
                role: item.element.role,
                frame: item.element.axFrame,
                visualFrame: nil,
                confidence: Double(item.score) / 100.0,
                source: .accessibility,
                appBundleID: nil,
                isMenuBar: true,
                axElement: item.element.element
            )
        }
    }

    // MARK: - AX Tree Traversal

    private struct CollectedAXElement {
        let element: AXUIElement
        let title: String
        let role: String
        let axFrame: CGRect
    }

    private func collectAXElements(
        from element: AXUIElement,
        into array: inout [CollectedAXElement],
        depth: Int,
        maxDepth: Int
    ) {
        guard depth < maxDepth else { return }

        let title       = readStringAttribute(kAXTitleAttribute, from: element)
        let description = readStringAttribute(kAXDescriptionAttribute, from: element)
        let value       = readStringAttribute(kAXValueAttribute, from: element)
        let role        = readStringAttribute(kAXRoleAttribute, from: element) ?? "AXUnknown"

        let bestTitle = [title, description, value]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })

        if let elementTitle = bestTitle {
            var frameRect = CGRect.zero
            var frameRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success,
               let frameValue = frameRef {
                AXValueGetValue(frameValue as! AXValue, .cgRect, &frameRect)
            }

            if frameRect.width > 0 && frameRect.height > 0 {
                array.append(CollectedAXElement(
                    element: element,
                    title: elementTitle,
                    role: role,
                    axFrame: frameRect
                ))
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }

        for child in children {
            collectAXElements(from: child, into: &array, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private func collectMenuBarElements(into array: inout [CollectedAXElement]) {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
            var menuBarRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
               let menuBarElement = menuBarRef {
                collectAXElements(from: menuBarElement as! AXUIElement, into: &array, depth: 0, maxDepth: 12)
            }
        }

        let systemProcessBundleIDs = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        for bundleID in systemProcessBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                collectAXElements(from: appElement, into: &array, depth: 0, maxDepth: 12)
            }
        }
    }

    // MARK: - Scoring

    private func scoreElement(_ element: CollectedAXElement, query: String) -> Int {
        var score = scoreLabel(element.title, against: query, role: element.role)
        guard score > 0 else { return 0 }

        // Penalize large elements — they are almost always container windows/groups,
        // not the clickable target. A Finder window titled "Downloads" would otherwise
        // beat the actual folder icon with the same exact-match score, causing the
        // cursor to fly to the window's center rather than the icon.
        //
        // We use max(1, ...) rather than allowing negative scores so that a container
        // is still included in results (with low priority) when it's the ONLY match
        // for a query — preventing an unnecessary fallback to AI screenshot pointing.
        let elementArea = element.axFrame.width * element.axFrame.height
        if elementArea > 200_000 {
            // Very large: likely a window, dialog, or full-pane content area
            score = max(1, score - 50)
        } else if elementArea > 60_000 {
            // Medium-large: likely a group, scroll area, or sidebar section
            score = max(1, score - 25)
        }

        // Penalize non-interactive container roles
        switch element.role {
        case "AXWindow", "AXSheet", "AXDrawer":
            score = max(1, score - 40)
        case "AXGroup", "AXScrollArea", "AXList", "AXTable", "AXOutline":
            score = max(1, score - 20)
        case "AXStaticText", "AXImage":
            // Text labels and images are rarely the action target
            score = max(1, score - 8)
        default:
            break
        }

        return score
    }

    private func scoreLabel(_ label: String, against query: String, role: String = "AXUnknown") -> Int {
        var score = 0
        let labelLower = label.lowercased()
        let queryLower = query.lowercased()

        if labelLower == queryLower {
            score += 100
        } else if labelLower.contains(queryLower) {
            score += 50
        } else if queryLower.contains(labelLower) && labelLower.count > 3 {
            score += 30
        }

        // Role bonuses — applied in scoreElement after size adjustments
        switch role {
        case "AXMenuBarItem": score += 15
        case "AXButton", "AXMenuItem": score += 10
        default: break
        }

        return score
    }

    // MARK: - Frame Overlap

    /// Returns the fraction of `frame1` that overlaps with `frame2`.
    private func frameOverlapFraction(_ frame1: CGRect, _ frame2: CGRect) -> Double {
        let intersection = frame1.intersection(frame2)
        guard !intersection.isNull && frame1.area > 0 else { return 0.0 }
        return Double(intersection.area / frame1.area)
    }

    // MARK: - AX Attribute Helpers

    private func readStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let stringValue = valueRef as? String,
              !stringValue.isEmpty else { return nil }
        return stringValue
    }
}

// MARK: - CGRect Area

private extension CGRect {
    var area: CGFloat { width * height }
}
