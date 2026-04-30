//
//  OfflineGuideManager.swift
//  leanring-buddy
//
//  Loads pre-built step-by-step guides from OfflineGuides.json and feeds them
//  directly into WalkthroughEngine when the user is offline or makes a request
//  that matches a known guide trigger keyword.
//

import Foundation
import Network

// MARK: - Data Models

/// The root wrapper decoded from OfflineGuides.json.
private struct OfflineGuidesFile: Decodable {
    let version: String
    let guides: [OfflineGuide]
}

/// One complete guide in OfflineGuides.json.
struct OfflineGuide: Decodable, Identifiable {
    let id: String
    let triggers: [String]
    let title: String
    let app: String
    let appBundleID: String?
    let steps: [OfflineGuideStep]
}

/// One step within an offline guide.
struct OfflineGuideStep: Decodable {
    let instruction: String
    let elementName: String?
    let elementRole: String?
    let isMenuBar: Bool
}

// MARK: - OfflineGuideManager

/// Matches user queries to pre-built offline guides and executes them via WalkthroughEngine.
/// Also monitors network reachability so callers can decide whether to use offline guides
/// or attempt a live API call.
final class OfflineGuideManager {
    static let shared = OfflineGuideManager()

    private var guides: [OfflineGuide] = []

    // NWPathMonitor for network reachability — a single long-lived monitor avoids
    // the overhead of creating a new one per request.
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.luma.networkMonitor", qos: .utility)

    /// True when the device has an active network connection.
    private(set) var isOnline: Bool = true

    private init() {
        loadGuidesFromBundle()
        startNetworkMonitoring()
    }

    // MARK: - Guide Loading

    private func loadGuidesFromBundle() {
        guard let url = Bundle.main.url(forResource: "OfflineGuides", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            LumaLogger.log("[OfflineGuides] OfflineGuides.json not found in bundle. Add it to the Xcode target's Copy Bundle Resources phase.")
            return
        }

        do {
            let decoded = try JSONDecoder().decode(OfflineGuidesFile.self, from: data)
            guides = decoded.guides
            LumaLogger.log("[OfflineGuides] Loaded \(guides.count) guide(s) (version \(decoded.version))")
        } catch {
            LumaLogger.log("[OfflineGuides] Failed to decode OfflineGuides.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Guide Matching

    /// Finds the best-matching guide for `query` using word-set matching.
    ///
    /// Instead of requiring the trigger phrase to be a literal substring of the query,
    /// this tokenizes both into individual words and checks whether ALL words from a
    /// trigger appear anywhere in the query (in any order). This means:
    ///   "Help me change my wallpaper" matches trigger "change wallpaper" ✓
    ///   "change my wallpaper"         matches trigger "change wallpaper" ✓
    ///   "change wallpaper"            matches trigger "change wallpaper" ✓
    ///
    /// When multiple guides match, the one whose matching trigger has the most words
    /// is preferred — longer trigger = more specific match = better intent signal.
    ///
    /// Returns nil if no guide has a trigger whose words are all present in the query.
    func findGuide(for query: String) -> OfflineGuide? {
        // Build a set of all individual words in the query for fast O(1) lookup.
        let queryWordSet = Set(
            query.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )

        var bestMatchedGuide: OfflineGuide? = nil
        var bestMatchedTriggerWordCount = 0

        for guide in guides {
            for trigger in guide.triggers {
                let triggerWords = trigger.lowercased()
                    .components(separatedBy: .alphanumerics.inverted)
                    .filter { !$0.isEmpty }

                guard !triggerWords.isEmpty else { continue }

                // All words in this trigger must appear somewhere in the query.
                let allTriggerWordsFoundInQuery = triggerWords.allSatisfy { queryWordSet.contains($0) }

                // Prefer the guide whose matching trigger is most specific (most words).
                if allTriggerWordsFoundInQuery && triggerWords.count > bestMatchedTriggerWordCount {
                    bestMatchedGuide = guide
                    bestMatchedTriggerWordCount = triggerWords.count
                }
            }
        }

        if let matched = bestMatchedGuide {
            LumaLogger.log("[OfflineGuides] Matched guide '\(matched.title)' (trigger word count: \(bestMatchedTriggerWordCount))")
        } else {
            LumaLogger.log("[OfflineGuides] No guide matched query: '\(query)'")
        }

        return bestMatchedGuide
    }

    /// Finds the best matching guide where ANY trigger word appears in the query.
    ///
    /// Less strict than `findGuide` (which requires ALL trigger words to be present):
    /// a single shared word between a trigger and the query is sufficient for a match.
    /// When multiple guides have matching triggers, the guide whose trigger has the
    /// most words present in the query is preferred (higher word-overlap = more specific).
    ///
    /// Returns the matched guide and the first trigger word that was found in the query,
    /// or nil when no trigger word from any guide appears in the query.
    ///
    /// Example:
    ///   query "show me battery info" → trigger "check battery" → matched keyword "battery"
    func findGuideByKeyword(for query: String) -> (guide: OfflineGuide, matchedKeyword: String)? {
        let queryWordSet = Set(
            query.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )

        var bestMatchedGuide: OfflineGuide? = nil
        var bestMatchedKeyword: String = ""
        var bestMatchedWordCount: Int = 0

        for guide in guides {
            for trigger in guide.triggers {
                let triggerWords = trigger.lowercased()
                    .components(separatedBy: .alphanumerics.inverted)
                    .filter { !$0.isEmpty }

                guard !triggerWords.isEmpty else { continue }

                // Count how many of this trigger's words appear in the query.
                let matchedTriggerWords = triggerWords.filter { queryWordSet.contains($0) }
                guard !matchedTriggerWords.isEmpty else { continue }

                // Prefer the trigger+guide with the most matched words — higher word-overlap
                // signals a more specific intent match.
                if matchedTriggerWords.count > bestMatchedWordCount {
                    bestMatchedGuide = guide
                    bestMatchedKeyword = matchedTriggerWords[0]
                    bestMatchedWordCount = matchedTriggerWords.count
                }
            }
        }

        guard let guide = bestMatchedGuide else { return nil }
        LumaLogger.log("[OfflineGuides] Keyword match: '\(bestMatchedKeyword)' → guide '\(guide.title)'")
        return (guide: guide, matchedKeyword: bestMatchedKeyword)
    }

    // MARK: - Guide Execution

    /// Converts an offline guide's steps into WalkthroughStep objects and feeds them
    /// directly into WalkthroughEngine — no API call needed.
    @MainActor
    func executeGuide(_ guide: OfflineGuide) {
        LumaLogger.log("[OfflineGuides] Executing guide '\(guide.title)' (\(guide.steps.count) step(s))")

        let walkthroughSteps = guide.steps.enumerated().map { index, step in
            WalkthroughStep(
                index: index,
                instruction: step.instruction,
                elementName: step.elementName ?? "",
                elementRole: step.elementRole,
                appBundleID: guide.appBundleID,
                isMenuBar: step.isMenuBar,
                timeoutSeconds: 15
            )
        }

        WalkthroughEngine.shared.executeSteps(walkthroughSteps)
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let nowOnline = path.status == .satisfied
            if self?.isOnline != nowOnline {
                self?.isOnline = nowOnline
                LumaLogger.log("[OfflineGuides] Network status changed: \(nowOnline ? "online" : "offline")")
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    /// Returns true when the user is offline AND there is a guide matching `query`.
    /// Callers check this before making an API request.
    func shouldUseOfflineGuide(for query: String) -> Bool {
        !isOnline && findGuide(for: query) != nil
    }
}
