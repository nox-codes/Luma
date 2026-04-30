//
//  OpenRouterModelFetcher.swift
//  leanring-buddy
//
//  Fetches the list of available models from the OpenRouter API via the
//  Cloudflare Worker proxy. Parses the response into a flat array of
//  OpenRouterModel structs for display in the model picker UI.
//

import Foundation
import Combine

/// A single model from the OpenRouter /models endpoint, with only the
/// fields the model picker needs.
struct OpenRouterModel: Identifiable, Equatable {
    let id: String
    let name: String
    let contextLength: Int
    let isFree: Bool

    /// Human-readable context length, e.g. "128K" or "1M".
    var formattedContextLength: String {
        if contextLength >= 1_000_000 {
            let millions = Double(contextLength) / 1_000_000.0
            if millions == millions.rounded() {
                return "\(Int(millions))M"
            }
            return String(format: "%.1fM", millions)
        }
        let thousands = contextLength / 1000
        return "\(thousands)K"
    }
}

/// Recommended model badges shown in the picker. Maps model IDs to short
/// labels so the UI can highlight curated picks.
enum RecommendedModelBadges {
    static let badgesByModelID: [String: String] = [
        "google/gemini-2.5-flash:free": "Best Free",
        "google/gemini-2.0-flash-exp:free": "Fast",
        "qwen/qwen2.5-vl-72b-instruct:free": "Best for Code",
        "anthropic/claude-sonnet-4-6": "Most Capable",
    ]

    static func badge(for modelID: String) -> String? {
        badgesByModelID[modelID]
    }
}

@MainActor
final class OpenRouterModelFetcher: ObservableObject {
    @Published var allModels: [OpenRouterModel] = []
    @Published var isLoadingModels: Bool = false
    @Published var modelFetchError: String?

    private let modelsURL: URL
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, baseURL: String = "https://openrouter.ai/api/v1") {
        self.apiKey = apiKey
        self.modelsURL = URL(string: "\(baseURL)/models")!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    /// Fetches the full model list from OpenRouter. Safe to call multiple
    /// times — skips the request if a fetch is already in progress.
    func fetchModelsIfNeeded() {
        guard !isLoadingModels else { return }

        // If we already have models cached, don't refetch on every panel open
        guard allModels.isEmpty else { return }

        isLoadingModels = true
        modelFetchError = nil

        Task {
            do {
                let models = try await fetchModelsFromAPI()
                self.allModels = models
            } catch {
                self.modelFetchError = error.localizedDescription
                LumaLogger.log("Failed to fetch OpenRouter models: \(error)")
            }
            self.isLoadingModels = false
        }
    }

    /// Forces a fresh fetch regardless of cache state.
    func refetchModels() {
        allModels = []
        fetchModelsIfNeeded()
    }

    private func fetchModelsFromAPI() async throws -> [OpenRouterModel] {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenRouterModelFetcher",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Models API error (\(statusCode)): \(errorBody)"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["data"] as? [[String: Any]] else {
            throw NSError(
                domain: "OpenRouterModelFetcher",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid models response format"]
            )
        }

        var parsedModels: [OpenRouterModel] = []
        for modelDict in modelsArray {
            guard let modelID = modelDict["id"] as? String,
                  let modelName = modelDict["name"] as? String else {
                continue
            }

            let contextLength = modelDict["context_length"] as? Int ?? 0

            // OpenRouter marks free models with zero pricing — check both
            // prompt and completion costs. The pricing dict may be absent
            // on free models, so treat missing pricing as non-free.
            let isFreeModel: Bool
            if let pricing = modelDict["pricing"] as? [String: Any] {
                let promptCost = pricing["prompt"] as? String ?? "1"
                let completionCost = pricing["completion"] as? String ?? "1"
                isFreeModel = (promptCost == "0" && completionCost == "0")
            } else {
                isFreeModel = false
            }

            parsedModels.append(OpenRouterModel(
                id: modelID,
                name: modelName,
                contextLength: contextLength,
                isFree: isFreeModel
            ))
        }

        // Sort recommended models first, then alphabetically by name
        parsedModels.sort { modelA, modelB in
            let modelAIsRecommended = RecommendedModelBadges.badge(for: modelA.id) != nil
            let modelBIsRecommended = RecommendedModelBadges.badge(for: modelB.id) != nil
            if modelAIsRecommended != modelBIsRecommended {
                return modelAIsRecommended
            }
            return modelA.name.localizedCaseInsensitiveCompare(modelB.name) == .orderedAscending
        }

        return parsedModels
    }
}
