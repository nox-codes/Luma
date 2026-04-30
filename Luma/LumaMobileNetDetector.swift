//
//  LumaMobileNetDetector.swift
//  leanring-buddy
//
//  3-layer visual UI element detection pipeline (on-device layers only).
//
//  Layer 1 (always runs): VNRecognizeTextRequest + VNDetectRectanglesRequest
//    Finds real bounding boxes for text labels and rectangular UI elements.
//    Results are scored by how closely recognized text matches the search query.
//    This replaces the broken VNClassificationObservation path that returned a
//    hardcoded (0,0,1,1) full-screen bounding box for every result, which was
//    causing every AX candidate to receive a spurious +0.3 cross-validation boost
//    in LumaImageProcessingEngine.crossValidate.
//
//  Layer 2 (runs when Layer 1 finds a match): MobileNetV2 presence check
//    Crops a 160×160 region around the Layer 1 bounding box center and runs
//    MobileNetV2 as a PRESENCE CHECK ONLY — not for name matching.
//    MobileNetV2 is an ImageNet classifier: it cannot match macOS UI element names.
//    Its only role is confirming that something visually exists at the coordinate
//    (any ImageNet class confidence > 0.1 = something is there, not a blank region).
//    Layer 1 results where no visual content is detected are downgraded (confidence ×= 0.5)
//    so they fall below the Layer 3 trigger threshold of 0.5.
//    Pass-through when MobileNetV2.mlmodelc is not bundled.
//
//  Layer 3 (last resort): Lives in LumaImageProcessingEngine.scanVisual.
//    Triggered when this detector returns no result above 0.5 confidence.
//    Uses APIClient.shared.analyzeImage with [POINT:x,y:label] response parsing.
//

import CoreML
import Vision
import AppKit

// MARK: - LumaMobileNetDetector

/// On-device visual element detector. Implements Layer 1 (Vision text + rectangles) and
/// Layer 2 (MobileNetV2 crop validation) of the 3-layer detection pipeline.
///
/// Returns `[VisualDetectionResult]` with real Quartz screen-coordinate bounding boxes.
/// Callers (LumaImageProcessingEngine.scanVisual) trigger Layer 3 when the returned
/// results have no confidence ≥ 0.5.
final class LumaMobileNetDetector {
    static let shared = LumaMobileNetDetector()

    /// The compiled VNCoreMLModel. Stored separately from any request so fresh
    /// VNCoreMLRequest instances can be created per crop in Layer 2 validation.
    /// A single shared VNCoreMLRequest is NOT thread-safe across concurrent
    /// VNImageRequestHandler calls — creating a fresh one per crop is required.
    private var vnCoreMLModel: VNCoreMLModel?

    private(set) var isModelAvailable: Bool = false

    private init() {
        loadModelIfAvailable()
    }

    // MARK: - Model Loading

    private func loadModelIfAvailable() {
        guard let modelURL = Bundle.main.url(forResource: "MobileNetV2", withExtension: "mlmodelc")
               ?? Bundle.main.url(forResource: "MobileNetV2", withExtension: "mlmodel") else {
            LumaLogger.log("[LumaMobileNet] MobileNetV2 not found in bundle — Layer 2 validation disabled. Layer 1 Vision requests still active.")
            return
        }

        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            vnCoreMLModel = try VNCoreMLModel(for: mlModel)
            isModelAvailable = true
            LumaLogger.log("[LumaMobileNet] MobileNetV2 loaded from \(modelURL.lastPathComponent) — Layer 2 active")
        } catch {
            LumaLogger.log("[LumaMobileNet] Failed to load MobileNetV2: \(error.localizedDescription)")
        }
    }

    // MARK: - Detection Entry Point

    /// Runs Layer 1 (Vision text + rectangles) then Layer 2 (MobileNet crop validation).
    ///
    /// Returns an empty array when Layer 1 finds no text matching `searchQuery` above the
    /// 0.5 confidence threshold. `LumaImageProcessingEngine.scanVisual` triggers Layer 3
    /// (APIClient) when the result is empty or all results have confidence < 0.5.
    func detectElements(
        in image: CGImage,
        screenSize: CGSize,
        searchQuery: String
    ) async -> [VisualDetectionResult] {
        let layer1Results = await runLayer1VisionDetection(
            on: image,
            screenSize: screenSize,
            searchQuery: searchQuery
        )
        guard !layer1Results.isEmpty else { return [] }
        return await applyLayer2MobileNetValidation(to: layer1Results, sourceImage: image)
    }

    // MARK: - Layer 1: Vision Text + Rectangle Detection

    /// Runs VNRecognizeTextRequest and VNDetectRectanglesRequest on `image`.
    ///
    /// For each recognized text observation:
    ///   resultConfidence = recognitionConfidence × computeQueryMatchWeight(text, searchQuery)
    ///
    /// Observations below 0.5 resultConfidence are discarded.
    ///
    /// A text observation whose Quartz screen frame overlaps > 50% with a detected
    /// rectangle gets a +0.1 confidence boost (capped at 1.0). Rectangles with no
    /// nearby matching text produce no standalone result.
    private func runLayer1VisionDetection(
        on image: CGImage,
        screenSize: CGSize,
        searchQuery: String
    ) async -> [VisualDetectionResult] {
        return await withCheckedContinuation { continuation in
            let textRecognitionRequest = VNRecognizeTextRequest()
            textRecognitionRequest.recognitionLevel = .accurate
            // Language correction is disabled — we want raw recognized text, not autocorrected,
            // so short labels like "Cmd+R" or "⌘N" are not mangled into dictionary words.
            textRecognitionRequest.usesLanguageCorrection = false

            let rectangleDetectionRequest = VNDetectRectanglesRequest()
            rectangleDetectionRequest.minimumAspectRatio = 0.1
            rectangleDetectionRequest.maximumAspectRatio = 10.0
            rectangleDetectionRequest.minimumSize = 0.01  // At least 1% of the image dimension
            rectangleDetectionRequest.maximumObservations = 20

            let imageRequestHandler = VNImageRequestHandler(cgImage: image, options: [:])

            do {
                try imageRequestHandler.perform([textRecognitionRequest, rectangleDetectionRequest])
            } catch {
                LumaLogger.log("[LumaMobileNet] Layer 1 Vision requests failed: \(error.localizedDescription)")
                continuation.resume(returning: [])
                return
            }

            let textObservations = textRecognitionRequest.results as? [VNRecognizedTextObservation] ?? []
            let rectangleObservations = rectangleDetectionRequest.results as? [VNRectangleObservation] ?? []

            var detectedResults: [VisualDetectionResult] = []

            for textObservation in textObservations {
                guard let topCandidate = textObservation.topCandidates(1).first else { continue }

                let queryMatchWeight = Self.computeQueryMatchWeight(
                    recognizedText: topCandidate.string,
                    searchQuery: searchQuery
                )
                guard queryMatchWeight > 0.0 else { continue }

                let resultConfidence = Double(topCandidate.confidence) * queryMatchWeight
                guard resultConfidence >= 0.5 else { continue }

                let quartzScreenFrame = Self.visionBoundingBoxToQuartzScreenFrame(
                    visionNormalizedBox: textObservation.boundingBox,
                    screenSize: screenSize
                )

                // A text label inside a detected rectangle is more likely to be a button or
                // interactive element — boost confidence when the frames overlap significantly.
                let hasOverlappingRectangle = rectangleObservations.contains { rectangleObservation in
                    let rectangleScreenFrame = Self.visionBoundingBoxToQuartzScreenFrame(
                        visionNormalizedBox: rectangleObservation.boundingBox,
                        screenSize: screenSize
                    )
                    let intersection = quartzScreenFrame.intersection(rectangleScreenFrame)
                    guard !intersection.isNull,
                          quartzScreenFrame.width > 0,
                          quartzScreenFrame.height > 0 else { return false }
                    let overlapFraction = (intersection.width * intersection.height)
                                       / (quartzScreenFrame.width * quartzScreenFrame.height)
                    return overlapFraction > 0.5
                }

                let boostedConfidence = hasOverlappingRectangle
                    ? min(resultConfidence + 0.1, 1.0)
                    : resultConfidence

                detectedResults.append(VisualDetectionResult(
                    label: topCandidate.string,
                    normalizedBoundingBox: textObservation.boundingBox,
                    confidence: boostedConfidence,
                    screenFrame: quartzScreenFrame
                ))
            }

            let sortedResults = detectedResults.sorted { $0.confidence > $1.confidence }
            LumaLogger.log("[LumaMobileNet] Layer 1: \(sortedResults.count) match(es) for '\(searchQuery)'")
            for result in sortedResults.prefix(3) {
                LumaLogger.log("[LumaMobileNet]   '\(result.label)' confidence=\(String(format: "%.2f", result.confidence))")
            }
            continuation.resume(returning: sortedResults)
        }
    }

    // MARK: - Coordinate Presence Check (public API)

    /// Checks whether a coordinate in `image` has any visible visual content.
    ///
    /// Crops a 160×160 region centred on `point`, runs MobileNetV2, and returns
    /// true if the top ImageNet classification confidence exceeds 0.1 — indicating
    /// that something visual (not a blank/empty region) exists at that location.
    ///
    /// This is a PRESENCE CHECK ONLY. MobileNetV2 is an ImageNet photo classifier and
    /// cannot match macOS UI element names. The Accessibility API owns all name matching.
    ///
    /// Returns true when MobileNetV2 is not bundled (pass-through: assume content present).
    func coordinateHasContent(at point: CGPoint, in image: CGImage) async -> Bool {
        guard isModelAvailable, let coreMLModel = vnCoreMLModel else {
            // Model not bundled — assume content is present so cursor movement is never blocked.
            return true
        }

        let cropRadius: CGFloat = 80
        let cropRect = CGRect(
            x: max(0, point.x - cropRadius),
            y: max(0, point.y - cropRadius),
            width: cropRadius * 2,
            height: cropRadius * 2
        )

        guard let croppedRegion = image.cropping(to: cropRect) else {
            // Crop failed (coordinate out of image bounds) — assume content is present.
            return true
        }

        return await withCheckedContinuation { continuation in
            // Create a fresh VNCoreMLRequest — VNCoreMLRequest is NOT thread-safe when
            // shared across concurrent VNImageRequestHandler calls.
            let presenceCheckRequest = VNCoreMLRequest(model: coreMLModel) { request, _ in
                let observations = request.results as? [VNClassificationObservation]
                let topConfidence = observations?.first?.confidence ?? 0.0
                // Any ImageNet class confidence > 0.1 means something is visually present.
                // We are NOT checking which class was detected — only that something is there.
                let hasContent = topConfidence > 0.1
                continuation.resume(returning: hasContent)
            }

            let requestHandler = VNImageRequestHandler(cgImage: croppedRegion, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try requestHandler.perform([presenceCheckRequest])
                } catch {
                    LumaLogger.log("[LumaMobileNet] coordinateHasContent failed: \(error.localizedDescription)")
                    // On error, assume content is present to avoid blocking cursor movement.
                    continuation.resume(returning: true)
                }
            }
        }
    }

    // MARK: - Layer 2: MobileNetV2 Presence Validation

    /// For each Layer 1 result, uses coordinateHasContent to confirm that something
    /// visually exists at the bounding box centre. Results where no content is detected
    /// are downgraded (confidence ×= 0.5) to fall below the Layer 3 trigger threshold.
    ///
    /// When MobileNetV2 is not bundled, all Layer 1 results pass through unchanged.
    private func applyLayer2MobileNetValidation(
        to layer1Results: [VisualDetectionResult],
        sourceImage: CGImage
    ) async -> [VisualDetectionResult] {
        guard isModelAvailable else {
            // Model not bundled — pass all Layer 1 results through without validation.
            // Layer 3 in LumaImageProcessingEngine still guards against false positives.
            return layer1Results
        }

        var validatedResults: [VisualDetectionResult] = []

        for layer1Result in layer1Results {
            let centerPoint = CGPoint(
                x: layer1Result.screenFrame.midX,
                y: layer1Result.screenFrame.midY
            )
            let hasContent = await coordinateHasContent(at: centerPoint, in: sourceImage)

            if hasContent {
                // Visual content confirmed at this coordinate — keep the Layer 1 result.
                validatedResults.append(layer1Result)
                LumaLogger.log("[LumaMobileNet] Layer 2: '\(layer1Result.label)' validated — content present at coordinate")
            } else {
                // Blank region detected — downgrade below the Layer 3 trigger threshold (0.5)
                // so LumaImageProcessingEngine.scanVisual fires Layer 3.
                validatedResults.append(VisualDetectionResult(
                    label: layer1Result.label,
                    normalizedBoundingBox: layer1Result.normalizedBoundingBox,
                    confidence: layer1Result.confidence * 0.5,
                    screenFrame: layer1Result.screenFrame
                ))
                LumaLogger.log("[LumaMobileNet] Layer 2: '\(layer1Result.label)' downgraded — blank region at coordinate")
            }
        }

        return validatedResults.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Coordinate Conversion

    /// Converts a Vision Framework normalized bounding box (bottom-left origin, 0–1 scale)
    /// to a Quartz/AX screen frame (top-left origin, absolute screen points).
    ///
    /// Vision uses bottom-left as the origin (like paper), while Quartz/AX use top-left on
    /// screen. The Y-flip formula:
    ///   quartzY = (1.0 - visionNormalizedBox.maxY) × screenHeight
    ///
    /// uses maxY (top of the box in Vision's bottom-left system = highest Y value) because
    /// that top edge maps to the smallest Quartz Y value (closest to the top-left origin).
    ///
    /// Static so it can be called without an instance reference in unit tests.
    static func visionBoundingBoxToQuartzScreenFrame(
        visionNormalizedBox: CGRect,
        screenSize: CGSize
    ) -> CGRect {
        let quartzX      = visionNormalizedBox.minX  * screenSize.width
        let quartzY      = (1.0 - visionNormalizedBox.maxY) * screenSize.height
        let quartzWidth  = visionNormalizedBox.width  * screenSize.width
        let quartzHeight = visionNormalizedBox.height * screenSize.height
        return CGRect(x: quartzX, y: quartzY, width: quartzWidth, height: quartzHeight)
    }

    // MARK: - Query Match Scoring

    /// Returns a 0.0–1.0 weight for how well `recognizedText` matches `searchQuery`.
    ///
    /// Multiplied by the Vision recognition confidence to produce the Layer 1 result confidence:
    ///   resultConfidence = recognitionConfidence × computeQueryMatchWeight(text, query)
    ///
    /// Match rules (checked in order of decreasing strength):
    ///   1.0 — exact match (case-insensitive)
    ///   0.7 — label contains the full query (e.g. "Save Document" ⊃ "Save")
    ///   0.4 — query contains the label, but only when label is > 3 chars (avoids matching
    ///          noise tokens like "OK" or "a" inside arbitrary query strings)
    ///   0.0 — no relationship (observation discarded by runLayer1VisionDetection)
    ///
    /// Static so it can be called without an instance reference in unit tests.
    static func computeQueryMatchWeight(recognizedText: String, searchQuery: String) -> Double {
        let textLower  = recognizedText.lowercased()
        let queryLower = searchQuery.lowercased()

        if textLower == queryLower {
            return 1.0
        } else if textLower.contains(queryLower) {
            return 0.7
        } else if queryLower.contains(textLower) && textLower.count > 3 {
            return 0.4
        }
        return 0.0
    }
}

// MARK: - VisualDetectionResult

/// A single detected UI element from the on-device detection pipeline.
struct VisualDetectionResult {
    /// The recognized text label (Layer 1 text recognition) or model-predicted class (legacy).
    let label: String
    /// Bounding box in normalized Vision coordinates (0–1, bottom-left origin).
    let normalizedBoundingBox: CGRect
    /// Detection confidence from 0.0 to 1.0, incorporating recognition quality and query match.
    let confidence: Double
    /// Bounding box in Quartz/AX screen coordinates (top-left origin, absolute screen points).
    /// Used for cross-validation against AX candidate frames in LumaImageProcessingEngine.
    let screenFrame: CGRect
}
