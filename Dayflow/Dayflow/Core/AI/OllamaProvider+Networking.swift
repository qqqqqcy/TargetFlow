//
//  OllamaProvider+Networking.swift
//  Dayflow
//

import Foundation

extension OllamaProvider {
  struct ChatRequest: Codable {
    var model: String
    let messages: [ChatMessage]
    var temperature: Double = 0.7
    var max_tokens: Int = 4000
    var stream: Bool = false
    var reasoning: Reasoning? = nil
    var reasoning_effort: String? = nil

    struct Reasoning: Codable {
      let effort: String
    }
  }

  struct ChatMessage: Codable {
    let role: String
    let content: [MessageContent]
  }

  struct MessageContent: Codable {
    let type: String
    let text: String?
    let image_url: ImageURL?

    struct ImageURL: Codable {
      let url: String
    }
  }

  struct ChatResponse: Codable {
    var model: String? = nil
    let choices: [Choice]

    struct Choice: Codable {
      let message: ResponseMessage
    }

    struct ResponseMessage: Codable {
      let content: String
    }
  }

  static func modelFeature(for operation: String) -> ModelFeature {
    switch operation {
    case "describe_frame", "transcribe_screenshots", "segment_video_activity": return .transcription
    case "generate_summary", "generate_title", "evaluate_card_merge", "merge_cards",
      "generate_cards", "generate_activity_cards": return .activityCards
    case "generate_timeline": return .timeline
    default: return .text
    }
  }

  func configuredRequest(
    _ request: ChatRequest, feature: ModelFeature, defaults: UserDefaults = AppStoragePaths.defaults
  ) -> ChatRequest {
    let isOpenRouter = URL(string: endpoint)?.host?.lowercased() == "openrouter.ai"
    let selection = ModelPreferences.resolve(
      provider: providerID, feature: feature, defaultModel: request.model,
      defaultEffort: request.reasoning?.effort, defaults: defaults)
    var result = request
    result.model = selection.model
    result.reasoning = nil
    result.reasoning_effort = nil
    if let effort = selection.reasoningEffort, effort != "default" {
      // Both protocols define `none`; omission keeps the server's own default.
      let value = effort == "disabled" ? "none" : effort
      if isOpenRouter {
        result.reasoning = .init(effort: value)
      } else {
        result.reasoning_effort = value
      }
    }
    return result
  }

  func makeChatURLRequest(
    _ request: ChatRequest,
    url: URL? = nil,
    timeoutInterval: TimeInterval = 60.0
  ) throws -> URLRequest {
    guard let resolvedURL = url ?? LocalEndpointUtilities.chatCompletionsURL(baseURL: endpoint)
    else {
      throw NSError(
        domain: "OllamaProvider", code: 15,
        userInfo: [NSLocalizedDescriptionKey: "Invalid local endpoint URL"])
    }

    var urlRequest = URLRequest(url: resolvedURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuthorizationHeader(to: &urlRequest)
    urlRequest.httpBody = try JSONEncoder().encode(request)
    urlRequest.timeoutInterval = timeoutInterval
    return urlRequest
  }

  func callChatAPI(
    _ request: ChatRequest, operation: String, batchId: Int64? = nil, maxRetries: Int = 3,
    feature: ModelFeature? = nil
  ) async throws -> ChatResponse {
    guard let url = LocalEndpointUtilities.chatCompletionsURL(baseURL: endpoint) else {
      throw NSError(
        domain: "OllamaProvider", code: 15,
        userInfo: [NSLocalizedDescriptionKey: "Invalid local endpoint URL"])
    }

    let request = configuredRequest(request, feature: feature ?? Self.modelFeature(for: operation))
    let fallbacks = AIRequestContext.assignment == nil
      ? (ModelPreferences.load(provider: providerID).fallbackModels ?? []) : []
    var seen: Set<String> = [request.model]
    let models = [request.model] + fallbacks.filter { seen.insert($0).inserted }
    for (modelIndex, model) in models.enumerated() {
      var modelRequest = request
      modelRequest.model = model
      do {
        return try await callConfiguredChatAPI(
          modelRequest, operation: operation, batchId: batchId, maxRetries: maxRetries, url: url)
      } catch {
        try Task.checkCancellation()
        if (error as NSError).code == NSURLErrorCancelled || modelIndex == models.count - 1 {
          throw error
        }
      }
    }
    preconditionFailure("At least one model is required")
  }

  private func callConfiguredChatAPI(
    _ request: ChatRequest, operation: String, batchId: Int64?, maxRetries: Int, url: URL
  ) async throws -> ChatResponse {
    // Retry logic with exponential backoff
    let attempts = max(1, maxRetries)
    var lastError: Error?

    let callGroupId = UUID().uuidString
    for attempt in 0..<attempts {
      var ctxForAttempt: LLMCallContext?
      var didLogFailureThisAttempt = false
      var didLogTiming = false
      var apiStart: Date?
      do {
        try Task.checkCancellation()
        let urlRequest = try makeChatURLRequest(request, url: url)

        let start = Date()
        apiStart = start
        let requestBodyForLogging: Data?
        if operation == "describe_frame" {
          // Don't persist raw base64 image payloads to the LLM call log (SQLite)
          requestBodyForLogging = nil
        } else {
          requestBodyForLogging = urlRequest.httpBody
        }
        let ctx = LLMCallContext(
          batchId: batchId,
          callGroupId: callGroupId,
          attempt: attempt + 1,
          provider: localEngine,  // Track actual engine: ollama, lmstudio, or custom
          providerID: providerID.rawValue,
          model: request.model,
          operation: operation,
          requestMethod: urlRequest.httpMethod,
          requestURL: urlRequest.url,
          requestHeaders: urlRequest.allHTTPHeaderFields,
          requestBody: requestBodyForLogging,
          startedAt: start
        )
        ctxForAttempt = ctx
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let requestDuration = Date().timeIntervalSince(start)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        logCallDuration(operation: operation, duration: requestDuration, status: statusCode)
        didLogTiming = true

        guard let httpResponse = response as? HTTPURLResponse else {
          throw NSError(
            domain: "OllamaProvider", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard httpResponse.statusCode == 200 else {
          let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
          // Log failure with response body via centralized logger
          let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
            acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }
          LLMLogger.logFailure(
            ctx: ctx,
            http: LLMHTTPInfo(
              httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders,
              responseBody: data),
            finishedAt: Date(),
            errorDomain: "OllamaProvider",
            errorCode: httpResponse.statusCode,
            errorMessage: errorBody
          )
          didLogFailureThisAttempt = true
          throw NSError(
            domain: "OllamaProvider", code: 4,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Ollama API request failed with status \(httpResponse.statusCode): \(errorBody)"
            ])
        }

        do {
          let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
          if let reported = chatResponse.model {
            print("[\(localEngine)] response model: \(reported) (requested: \(request.model))")
          }
          ModelExecutionHistory.shared.record(
            provider: providerID.rawValue, requestedModel: request.model,
            reportedModels: chatResponse.model.map { [$0] } ?? [],
            requestedReasoning: request.reasoning?.effort ?? request.reasoning_effort,
            startedAt: start, outcome: .succeeded)
          // Centralized success log
          let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
            acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }
          LLMLogger.logSuccess(
            ctx: ctx,
            http: LLMHTTPInfo(
              httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders,
              responseBody: data),
            finishedAt: Date()
          )
          return chatResponse
        } catch {
          // Centralized parse failure
          let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) {
            acc, kv in
            if let k = kv.key as? String, let v = kv.value as? CustomStringConvertible {
              acc[k] = v.description
            }
          }
          LLMLogger.logFailure(
            ctx: ctx,
            http: LLMHTTPInfo(
              httpStatus: httpResponse.statusCode, responseHeaders: responseHeaders,
              responseBody: data),
            finishedAt: Date(),
            errorDomain: (error as NSError).domain,
            errorCode: (error as NSError).code,
            errorMessage: (error as NSError).localizedDescription
          )
          didLogFailureThisAttempt = true
          throw error
        }

      } catch {
        ModelExecutionHistory.shared.record(
          provider: providerID.rawValue, requestedModel: request.model,
          requestedReasoning: request.reasoning?.effort ?? request.reasoning_effort,
          startedAt: apiStart ?? Date(), outcome: .failed,
          failureCode: "request_failed_\((error as NSError).code)")
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw error }
        lastError = error
        if !didLogTiming, let startedAt = apiStart {
          let requestDuration = Date().timeIntervalSince(startedAt)
          logCallDuration(operation: operation, duration: requestDuration, status: nil)
          didLogTiming = true
        }
        print("[OLLAMA] Request failed (attempt \(attempt + 1)/\(attempts)): \(error)")

        // If it's not the last attempt, wait before retrying
        if attempt < attempts - 1 {
          let backoffDelay = pow(2.0, Double(attempt)) * 2.0  // 2s, 4s, 8s
          try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
        }
        // Network error log without http info
        if !didLogFailureThisAttempt {
          let fallbackBodyForLogging: Data?
          if operation == "describe_frame" {
            fallbackBodyForLogging = nil
          } else {
            fallbackBodyForLogging = try? JSONEncoder().encode(request)
          }
          let ctx =
            ctxForAttempt
            ?? LLMCallContext(
              batchId: batchId,
              callGroupId: callGroupId,
              attempt: attempt + 1,
              provider: localEngine,  // Track actual engine: ollama, lmstudio, or custom
              providerID: providerID.rawValue,
              model: request.model,
              operation: operation,
              requestMethod: "POST",
              requestURL: url,
              requestHeaders: ["Content-Type": "application/json"],
              requestBody: fallbackBodyForLogging,
              startedAt: Date()
            )
          LLMLogger.logFailure(
            ctx: ctx,
            http: nil,
            finishedAt: Date(),
            errorDomain: (error as NSError).domain,
            errorCode: (error as NSError).code,
            errorMessage: (error as NSError).localizedDescription
          )
          didLogFailureThisAttempt = true
        }
      }
    }

    throw lastError
      ?? NSError(
        domain: "OllamaProvider", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Request failed after \(attempts) attempts"])
  }

  // (no local logging helpers needed; centralized via LLMLogger)

  // Helper method for text-only requests
  func callTextAPI(
    _ prompt: String, operation: String, expectJSON: Bool = false, batchId: Int64? = nil,
    maxRetries: Int = 3, maxTokens: Int = 4000, feature: ModelFeature? = nil
  ) async throws -> String {
    let systemPrompt =
      expectJSON
      ? "You are a helpful assistant. Always respond with valid JSON."
      : "You are a helpful assistant."

    let request = ChatRequest(
      model: savedModelId,
      messages: [
        ChatMessage(
          role: "system",
          content: [MessageContent(type: "text", text: systemPrompt, image_url: nil)]),
        ChatMessage(
          role: "user", content: [MessageContent(type: "text", text: prompt, image_url: nil)]),
      ],
      temperature: 0.7,
      max_tokens: maxTokens,
      stream: false
    )

    let response = try await callChatAPI(
      request, operation: operation, batchId: batchId, maxRetries: maxRetries, feature: feature)
    return response.choices.first?.message.content ?? ""
  }

  private func applyAuthorizationHeader(to request: inout URLRequest) {
    if let token = authorizationBearerToken {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }
}

// MARK: - Text Generation

extension OllamaProvider {
  func generateText(prompt: String, maxTokens: Int = 4000, feature: ModelFeature = .text) async throws
    -> (text: String, log: LLMCall)
  {
    let callStart = Date()

    let response = try await callTextAPI(
      prompt,
      operation: "generate_text",
      expectJSON: false,
      batchId: nil,
      maxRetries: 3,
      maxTokens: maxTokens,
      feature: feature
    )

    let log = LLMCall(
      timestamp: callStart,
      latency: Date().timeIntervalSince(callStart),
      input: prompt,
      output: response
    )

    return (response.trimmingCharacters(in: .whitespacesAndNewlines), log)
  }
}
