import Foundation

// MARK: - APIClient

/// Singleton that routes AI requests to whichever profile the user has set as default.
/// Replaces the old Cloudflare Worker proxy — requests now go directly to the provider
/// using API keys stored in the macOS Keychain via ProfileManager/KeychainManager.
///
/// Method signatures intentionally match ClaudeAPI so CompanionManager needs minimal changes.
@MainActor
final class APIClient {

    static let shared = APIClient()

    // Named constants for timeout values — avoids magic numbers scattered through the code
    private let requestTimeoutSeconds: TimeInterval = 120
    private let resourceTimeoutSeconds: TimeInterval = 300
    private let tlsWarmupTimeoutSeconds: TimeInterval = 10

    // Thread-safety lock for the one-time TLS warmup flag.
    // NSLock is used (rather than an actor) because warmup fires from init, before
    // the surrounding @MainActor context is established.
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    /// The model to use for requests.
    /// Stored here so CompanionManager can set it via apiClient.model = selectedModel,
    /// matching the interface it used with ClaudeAPI.
    var model: String = ""

    /// Shared URLSession — .default (not .ephemeral) so TLS session tickets are cached.
    /// Ephemeral sessions do a full TLS handshake on every request, causing transient
    /// -1200 (errSSLPeerHandshakeFail) errors on large image payloads.
    /// URL cache and cookie storage are disabled to keep nothing on disk.
    private let urlSession: URLSession

    // MARK: - Request Queue
    //
    // Anthropic's free tier allows 5 requests/minute (~12s apart). We enforce 15s between
    // requests and allow at most one concurrent request so walkthrough validation calls
    // can never stack up and hit the limit. All callers await acquireRequestSlot() before
    // touching the network and call releaseRequestSlot() in a defer block after.

    private var isRequestActive: Bool = false
    private var lastRequestFinishedDate: Date = .distantPast
    private let minimumSecondsBetweenRequests: TimeInterval = 15.0
    /// Continuations for callers waiting for the request slot to open.
    private var queuedRequestContinuations: [CheckedContinuation<Void, Never>] = []

    /// Waits until no other request is running and the 15-second cooldown has elapsed,
    /// then atomically marks the slot as taken.
    ///
    /// The slot is marked active BEFORE the cooldown sleep so no concurrent caller can
    /// slip in between the check and the sleep.
    private func acquireRequestSlot() async {
        if isRequestActive {
            // Another request is running — join the queue
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queuedRequestContinuations.append(continuation)
            }
            // When resumed, we inherit the slot — releaseRequestSlot did NOT clear isRequestActive
        } else {
            isRequestActive = true
        }

        // Enforce minimum gap from the end of the previous request.
        // isRequestActive == true here, so new callers cannot race past this await.
        let elapsed = Date().timeIntervalSince(lastRequestFinishedDate)
        if elapsed < minimumSecondsBetweenRequests {
            let remainingCooldownSeconds = minimumSecondsBetweenRequests - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remainingCooldownSeconds * 1_000_000_000))
        }
    }

    /// Releases the slot and wakes the next queued caller, if any.
    ///
    /// When there is a waiting caller, isRequestActive is left true so the woken caller
    /// inherits the slot directly — no gap where a third caller could slip through.
    private func releaseRequestSlot() {
        lastRequestFinishedDate = Date()

        if let nextContinuation = queuedRequestContinuations.first {
            queuedRequestContinuations.removeFirst()
            // Caller inherits the active slot; do NOT set isRequestActive = false here
            nextContinuation.resume()
        } else {
            isRequestActive = false
        }
    }

    private init() {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 120   // requestTimeoutSeconds — can't use self yet
        sessionConfig.timeoutIntervalForResource = 300  // resourceTimeoutSeconds — can't use self yet
        sessionConfig.waitsForConnectivity = true
        sessionConfig.urlCache = nil
        sessionConfig.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: sessionConfig)

        // Pre-establish the TLS connection to the active profile's host so the first
        // real request (which carries a large screenshot payload) doesn't bear the cost
        // of a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    // MARK: - TLS Warmup

    /// Fires a lightweight HEAD request to the active profile's base host to pre-cache
    /// the TLS session ticket. Runs once per app launch. Failures are silently ignored.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        // Grab the active profile's base URL for warmup targeting.
        // If no profile is set yet, we fall back to a well-known host so the warmup
        // isn't wasted — the user will configure a profile before making real requests.
        let activeProfileBaseURL = ProfileManager.shared.activeProfile?.effectiveBaseURL
            ?? "https://openrouter.ai"

        guard let warmupURLComponents = URLComponents(string: activeProfileBaseURL),
              var mutableWarmupComponents = Optional(warmupURLComponents) else {
            return
        }

        // The TLS ticket is scoped to the host, so hitting "/" is enough.
        // We strip the path/query/fragment to avoid hitting an actual API endpoint.
        mutableWarmupComponents.path = "/"
        mutableWarmupComponents.query = nil
        mutableWarmupComponents.fragment = nil

        guard let warmupURL = mutableWarmupComponents.url else { return }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = tlsWarmupTimeoutSeconds

        urlSession.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — caching the TLS handshake is the goal
        }.resume()
    }

    // MARK: - Request Building

    /// Resolves the active profile and API key, or throws a user-facing error.
    private func resolveActiveProfileAndAPIKey() throws -> (profile: LumaAPIProfile, apiKey: String) {
        guard let activeProfile = ProfileManager.shared.activeProfile else {
            throw NSError(
                domain: "APIClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No API profile configured. Please add a profile in Settings."]
            )
        }

        guard let apiKey = ProfileManager.shared.loadActiveAPIKey(), !apiKey.isEmpty else {
            throw NSError(
                domain: "APIClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No API key found for the active profile \"\(activeProfile.name)\". Please add your key in Settings."]
            )
        }

        return (activeProfile, apiKey)
    }

    /// Builds the full chat completions URL for the given profile.
    /// Anthropic uses `/messages`; all OpenAI-compatible providers use `/chat/completions`.
    private func buildChatEndpointURL(forProfile profile: LumaAPIProfile) throws -> URL {
        let endpointPath: String
        switch profile.provider {
        case .anthropic:
            endpointPath = "/messages"
        default:
            endpointPath = "/chat/completions"
        }

        let fullURLString = profile.effectiveBaseURL + endpointPath

        guard let endpointURL = URL(string: fullURLString) else {
            throw NSError(
                domain: "APIClient",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint URL: \(fullURLString)"]
            )
        }

        return endpointURL
    }

    /// Creates a URLRequest with auth headers set for the given profile.
    private func buildAuthenticatedURLRequest(
        forURL endpointURL: URL,
        profile: LumaAPIProfile,
        apiKey: String
    ) -> URLRequest {
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Anthropic uses a custom header name (x-api-key) without a "Bearer" prefix.
        // All OpenAI-compatible providers use "Authorization: Bearer <key>".
        let authHeaderValue: String
        if profile.provider.requiresBearerPrefix {
            authHeaderValue = "Bearer \(apiKey)"
        } else {
            authHeaderValue = apiKey
        }
        urlRequest.setValue(authHeaderValue, forHTTPHeaderField: profile.provider.authHeaderName)

        // Anthropic requires the API version header to be present
        if profile.provider == .anthropic {
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        return urlRequest
    }

    // MARK: - Request Body Building

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Builds the Anthropic-format request body.
    /// Anthropic's API expects the system prompt as a top-level key, not as a message.
    /// Images use the `source` block format with base64 data.
    private func buildAnthropicRequestBody(
        modelID: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        shouldStream: Bool,
        maxOutputTokens: Int
    ) throws -> Data {
        var messages: [[String: Any]] = []

        // Replay the conversation history so the model has context from prior turns
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build the current user message with all labeled screenshots and the text prompt
        var currentUserContentBlocks: [[String: Any]] = []
        for image in images {
            // Each image gets its own content block in Anthropic's format
            currentUserContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            // The label (e.g. "Screen 1") immediately follows the image so the model
            // knows which display each screenshot belongs to
            currentUserContentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        currentUserContentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": currentUserContentBlocks])

        let requestBody: [String: Any] = [
            "model": modelID,
            "max_tokens": maxOutputTokens,
            "stream": shouldStream,
            "system": systemPrompt,
            "messages": messages
        ]

        return try JSONSerialization.data(withJSONObject: requestBody)
    }

    /// Builds the OpenAI-compatible request body.
    /// Used for OpenRouter, Google, and Custom providers.
    /// The system prompt is sent as a system-role message.
    /// Images use the `image_url` format with a data URI.
    private func buildOpenAICompatibleRequestBody(
        modelID: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        shouldStream: Bool,
        maxOutputTokens: Int
    ) throws -> Data {
        var messages: [[String: Any]] = []

        // OpenAI-compatible APIs take the system prompt as an explicit system message
        messages.append(["role": "system", "content": systemPrompt])

        // Replay the conversation history so the model has context from prior turns
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build the current user message.
        // When there are no images, send content as a plain string — this is more broadly
        // compatible across providers than wrapping a lone text block in an array.
        // When images are present, use the content array format with image_url blocks.
        if images.isEmpty {
            messages.append(["role": "user", "content": userPrompt])
        } else {
            var currentUserContentBlocks: [[String: Any]] = []
            for image in images {
                // OpenAI-compatible APIs use data URIs inside an image_url object
                let imageMimeType = detectImageMediaType(for: image.data)
                let base64EncodedImageData = image.data.base64EncodedString()
                let imageDataURI = "data:\(imageMimeType);base64,\(base64EncodedImageData)"
                currentUserContentBlocks.append([
                    "type": "image_url",
                    "image_url": ["url": imageDataURI]
                ])
                // The label (e.g. "Screen 1") immediately follows the image so the model
                // knows which display each screenshot belongs to
                currentUserContentBlocks.append([
                    "type": "text",
                    "text": image.label
                ])
            }
            currentUserContentBlocks.append([
                "type": "text",
                "text": userPrompt
            ])
            messages.append(["role": "user", "content": currentUserContentBlocks])
        }

        let requestBody: [String: Any] = [
            "model": modelID,
            "max_tokens": maxOutputTokens,
            "stream": shouldStream,
            "messages": messages
        ]

        return try JSONSerialization.data(withJSONObject: requestBody)
    }

    // MARK: - SSE Parsing

    /// Extracts the text chunk from a single Anthropic SSE data line.
    /// Anthropic streams content_block_delta events with a text_delta type.
    private func extractTextChunkFromAnthropicSSELine(_ jsonString: String) -> String? {
        guard let jsonData = jsonString.data(using: .utf8),
              let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let eventType = eventPayload["type"] as? String,
              eventType == "content_block_delta",
              let delta = eventPayload["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String,
              deltaType == "text_delta",
              let textChunk = delta["text"] as? String
        else {
            return nil
        }
        return textChunk
    }

    /// Extracts the text chunk from a single OpenAI-compatible SSE data line.
    /// OpenAI-compatible APIs stream choices[0].delta.content.
    private func extractTextChunkFromOpenAICompatibleSSELine(_ jsonString: String) -> String? {
        guard let jsonData = jsonString.data(using: .utf8),
              let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = eventPayload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let textChunk = delta["content"] as? String
        else {
            return nil
        }
        return textChunk
    }

    // MARK: - Public API

    /// Sends a vision request to the active profile's provider with SSE streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total wall-clock duration when the stream ends.
    ///
    /// The active profile is read on each call (not cached), so profile switches take effect immediately.
    ///
    /// - Parameter maxOutputTokens: Token budget for the response. Default 1024 — enough for
    ///   conversational voice responses (2-4 sentences). Callers that need longer structured output
    ///   (e.g. JSON planning) should use `analyzeImage` with a higher limit instead.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        maxOutputTokens: Int = 1024,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }

        let startTime = Date()

        // Resolve the profile and key fresh on each request so profile changes are instant
        let (activeProfile, apiKey) = try resolveActiveProfileAndAPIKey()
        let endpointURL = try buildChatEndpointURL(forProfile: activeProfile)
        var urlRequest = buildAuthenticatedURLRequest(
            forURL: endpointURL,
            profile: activeProfile,
            apiKey: apiKey
        )

        // The model comes exclusively from the active profile — no hardcoded fallbacks.
        // If the user hasn't set a model in Settings → Model, surface a clear error rather
        // than silently sending the wrong model to the API.
        let effectiveModelID = activeProfile.selectedModel.trimmingCharacters(in: .whitespaces)
        guard !effectiveModelID.isEmpty else {
            throw NSError(
                domain: "APIClient",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "No model configured for profile \"\(activeProfile.name)\". Go to Settings → Model and enter a model ID."]
            )
        }

        // Diagnostic log — printed on every request so console always shows exactly
        // what provider/endpoint/model/key is being used, without guessing.
        let maskedAPIKey = apiKey.count > 8
            ? String(apiKey.prefix(4)) + "…" + String(apiKey.suffix(4))
            : String(repeating: "*", count: apiKey.count)
        LumaLogger.log("APIClient ▶ provider=\(activeProfile.provider.displayName) endpoint=\(endpointURL.absoluteString) model=\(effectiveModelID) key=\(maskedAPIKey)")

        // Build the request body in the format expected by this provider
        let requestBodyData: Data
        switch activeProfile.provider {
        case .anthropic:
            requestBodyData = try buildAnthropicRequestBody(
                modelID: effectiveModelID,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                shouldStream: true,
                maxOutputTokens: maxOutputTokens
            )
        default:
            requestBodyData = try buildOpenAICompatibleRequestBody(
                modelID: effectiveModelID,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                shouldStream: true,
                maxOutputTokens: maxOutputTokens
            )
        }

        urlRequest.httpBody = requestBodyData
        let payloadSizeMB = Double(requestBodyData.count) / 1_048_576.0
        LumaLogger.log("APIClient: streaming request to \(activeProfile.provider.displayName) — \(String(format: "%.1f", payloadSizeMB))MB, \(images.count) image(s), max_tokens=\(maxOutputTokens)")

        // Use bytes streaming to read the SSE response line by line.
        // On a 429 rate-limit response, wait 60 seconds and retry exactly once.
        // If the retry also fails, throw — no further retries.
        var byteStream: URLSession.AsyncBytes
        var httpURLResponse: HTTPURLResponse

        let (firstByteStream, firstHTTPResponse) = try await urlSession.bytes(for: urlRequest)
        guard let firstHTTPURLResponse = firstHTTPResponse as? HTTPURLResponse else {
            throw NSError(
                domain: "APIClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from \(activeProfile.provider.displayName)"]
            )
        }

        if firstHTTPURLResponse.statusCode == 429 {
            LumaLogger.log("[APIClient] Rate limit (429) on streaming — waiting 60 seconds before single retry")
            try await Task.sleep(nanoseconds: 60_000_000_000)
            let (retryByteStream, retryHTTPResponse) = try await urlSession.bytes(for: urlRequest)
            guard let retryHTTPURLResponse = retryHTTPResponse as? HTTPURLResponse else {
                throw NSError(
                    domain: "APIClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response on retry from \(activeProfile.provider.displayName)"]
                )
            }
            byteStream = retryByteStream
            httpURLResponse = retryHTTPURLResponse
        } else {
            byteStream = firstByteStream
            httpURLResponse = firstHTTPURLResponse
        }

        // Non-2xx responses carry the error detail in the body — read it and surface it
        guard (200...299).contains(httpURLResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            let errorBody = errorBodyLines.joined(separator: "\n")
            throw NSError(
                domain: "APIClient",
                code: httpURLResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(activeProfile.provider.displayName) API Error (\(httpURLResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await sseRawLine in byteStream.lines {
            // SSE lines look like "data: {...}" — skip anything else (comments, empty lines, event: lines)
            guard sseRawLine.hasPrefix("data: ") else { continue }
            let jsonString = String(sseRawLine.dropFirst(6)) // Drop the "data: " prefix

            // Both Anthropic and OpenAI-compatible streams signal end-of-stream with [DONE]
            guard jsonString != "[DONE]" else { break }

            // Extract the text chunk using the parser appropriate for this provider
            let textChunk: String?
            switch activeProfile.provider {
            case .anthropic:
                textChunk = extractTextChunkFromAnthropicSSELine(jsonString)
            default:
                textChunk = extractTextChunkFromOpenAICompatibleSSELine(jsonString)
            }

            if let textChunk = textChunk {
                accumulatedResponseText += textChunk
                // Pass the full accumulated text (not just the chunk) so the UI can
                // always render a complete string without needing to append on its end
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: totalDuration)
    }

    /// Non-streaming fallback for validation requests where progressive display isn't needed.
    /// Returns the full response text and wall-clock duration.
    ///
    /// The active profile is read on each call (not cached), so profile switches take effect immediately.
    ///
    /// - Parameter maxOutputTokens: Token budget for the response. Default 2048 — enough for
    ///   full JSON task plans (5+ steps). Callers that only need a short answer (e.g. "COMPLETED")
    ///   can pass a lower value to reduce latency.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        maxOutputTokens: Int = 2048
    ) async throws -> (text: String, duration: TimeInterval) {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }

        let startTime = Date()

        // Resolve the profile and key fresh on each request so profile changes are instant
        let (activeProfile, apiKey) = try resolveActiveProfileAndAPIKey()
        let endpointURL = try buildChatEndpointURL(forProfile: activeProfile)
        var urlRequest = buildAuthenticatedURLRequest(
            forURL: endpointURL,
            profile: activeProfile,
            apiKey: apiKey
        )

        let effectiveModelID = activeProfile.selectedModel.trimmingCharacters(in: .whitespaces)
        guard !effectiveModelID.isEmpty else {
            throw NSError(
                domain: "APIClient",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "No model configured for profile \"\(activeProfile.name)\". Go to Settings → Model and enter a model ID."]
            )
        }

        let maskedAPIKey = apiKey.count > 8
            ? String(apiKey.prefix(4)) + "…" + String(apiKey.suffix(4))
            : String(repeating: "*", count: apiKey.count)
        LumaLogger.log("[APIClient] provider=\(activeProfile.provider.displayName) endpoint=\(endpointURL.absoluteString) model=\(effectiveModelID) key=\(maskedAPIKey)")

        // Build the request body in the format expected by this provider (non-streaming)
        let requestBodyData: Data
        switch activeProfile.provider {
        case .anthropic:
            requestBodyData = try buildAnthropicRequestBody(
                modelID: effectiveModelID,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                shouldStream: false,
                maxOutputTokens: maxOutputTokens
            )
        default:
            requestBodyData = try buildOpenAICompatibleRequestBody(
                modelID: effectiveModelID,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                shouldStream: false,
                maxOutputTokens: maxOutputTokens
            )
        }

        urlRequest.httpBody = requestBodyData
        let payloadSizeMB = Double(requestBodyData.count) / 1_048_576.0
        LumaLogger.log("[APIClient] non-streaming request to \(activeProfile.provider.displayName) — \(String(format: "%.1f", payloadSizeMB))MB, \(images.count) image(s), max_tokens=\(maxOutputTokens)")

        // On a 429 rate-limit response, wait 60 seconds and retry exactly once.
        // If the retry also fails, throw — no further retries.
        let responseData: Data
        let httpURLResponse: HTTPURLResponse

        let (firstResponseData, firstHTTPResponse) = try await urlSession.data(for: urlRequest)
        guard let firstHTTPURLResponse = firstHTTPResponse as? HTTPURLResponse else {
            throw NSError(
                domain: "APIClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from \(activeProfile.provider.displayName)"]
            )
        }

        if firstHTTPURLResponse.statusCode == 429 {
            LumaLogger.log("[APIClient] Rate limit (429) — waiting 60 seconds before single retry")
            try await Task.sleep(nanoseconds: 60_000_000_000)
            let (retryResponseData, retryHTTPResponse) = try await urlSession.data(for: urlRequest)
            guard let retryHTTPURLResponse = retryHTTPResponse as? HTTPURLResponse else {
                throw NSError(
                    domain: "APIClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response on retry from \(activeProfile.provider.displayName)"]
                )
            }
            responseData = retryResponseData
            httpURLResponse = retryHTTPURLResponse
        } else {
            responseData = firstResponseData
            httpURLResponse = firstHTTPURLResponse
        }

        guard (200...299).contains(httpURLResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "APIClient",
                code: httpURLResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(activeProfile.provider.displayName) API Error (\(httpURLResponse.statusCode)): \(errorBody)"]
            )
        }

        let parsedJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]

        // Extract the response text using the format appropriate for this provider
        let responseText: String
        switch activeProfile.provider {
        case .anthropic:
            // Anthropic returns: { "content": [{ "type": "text", "text": "..." }] }
            guard let contentBlocks = parsedJSON?["content"] as? [[String: Any]],
                  let firstTextBlock = contentBlocks.first(where: { ($0["type"] as? String) == "text" }),
                  let extractedText = firstTextBlock["text"] as? String
            else {
                throw NSError(
                    domain: "APIClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected Anthropic response format — could not find text content"]
                )
            }
            responseText = extractedText

        default:
            // OpenAI-compatible returns: { "choices": [{ "message": { "content": "..." } }] }
            // The content field is normally a String, but thinking models (e.g. Gemini 2.5 Flash)
            // may return it as an array of typed content blocks. Handle both to avoid a cast
            // failure silently propagating up as a planning failure.
            guard let choices = parsedJSON?["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any]
            else {
                throw NSError(
                    domain: "APIClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected \(activeProfile.provider.displayName) response format — could not find choices/message"]
                )
            }

            if let textContent = message["content"] as? String {
                // Standard string content — most models
                responseText = textContent
            } else if let contentBlocks = message["content"] as? [[String: Any]] {
                // Thinking-model array content — concatenate all text-type blocks
                let assembledText = contentBlocks.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }.joined()
                guard !assembledText.isEmpty else {
                    throw NSError(
                        domain: "APIClient",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "\(activeProfile.provider.displayName) returned content blocks but no text blocks were found"]
                    )
                }
                responseText = assembledText
            } else {
                throw NSError(
                    domain: "APIClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected \(activeProfile.provider.displayName) response format — content field was neither String nor content-block array"]
                )
            }
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        return (text: responseText, duration: totalDuration)
    }
}
