//
//  OllamaProvider.swift
//  Dayflow
//

import AppKit
import Foundation

final class OllamaProvider {
  let endpoint: String
  private let injectedRuntimeConfiguration: OpenAICompatibleRuntimeConfiguration?
  let screenshotInterval: TimeInterval = 10  // seconds between screenshots
  // Read persisted local settings
  var savedModelId: String {
    if let injectedRuntimeConfiguration {
      return injectedRuntimeConfiguration.modelID
    }
    if let m = AppStoragePaths.defaults.string(forKey: "llmLocalModelId"), !m.isEmpty {
      return m
    }
    // Fallback to a sensible default
    let engine: LocalEngine = isLMStudio ? .lmstudio : .ollama
    return LocalModelPreferences.defaultModelId(for: engine)
  }
  var isLMStudio: Bool {
    guard injectedRuntimeConfiguration == nil else { return false }
    return (AppStoragePaths.defaults.string(forKey: "llmLocalEngine") ?? "ollama") == "lmstudio"
  }
  var isCustomEngine: Bool {
    guard injectedRuntimeConfiguration == nil else { return false }
    return (AppStoragePaths.defaults.string(forKey: "llmLocalEngine") ?? "ollama") == "custom"
  }
  var customAPIKey: String? {
    guard injectedRuntimeConfiguration == nil else { return nil }
    let trimmed =
      AppStoragePaths.defaults.string(forKey: "llmLocalAPIKey")?.trimmingCharacters(
        in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  // Get the actual local engine type for analytics tracking
  var localEngine: String {
    if let injectedRuntimeConfiguration {
      return injectedRuntimeConfiguration.analyticsProvider
    }
    return AppStoragePaths.defaults.string(forKey: "llmLocalEngine") ?? "ollama"
  }

  var providerID: LLMProviderID {
    injectedRuntimeConfiguration == nil ? .local : .openAICompatible
  }

  var authorizationBearerToken: String? {
    if let injectedRuntimeConfiguration {
      return injectedRuntimeConfiguration.bearerToken
    }
    if isLMStudio {
      return "lm-studio"
    }
    if isCustomEngine {
      return customAPIKey
    }
    return nil
  }

  var promptOverrides: ActivityCardPromptOverrides {
    ActivityCardPromptPreferences.load()
  }

  init(openAICompatible configuration: OpenAICompatibleRuntimeConfiguration) {
    self.endpoint = configuration.endpoint
    self.injectedRuntimeConfiguration = configuration
  }

  // Strip user references from observations to prevent LLM from using third-person language
  // For some reason, even after adding negative prompts during observation generation,
  // it still generates text with "a user" and "the user", which poisons the context
  // for the summary prompt and makes it more likely to write in 3rd person.
  // TODO: Remove this when observation generation is fixed upstream
  func stripUserReferences(_ text: String) -> String {
    return
      text
      .replacingOccurrences(of: "The user", with: "", options: .caseInsensitive)
      .replacingOccurrences(of: "A user", with: "", options: .caseInsensitive)
  }

  func logCallDuration(operation: String, duration: TimeInterval, status: Int? = nil) {
    let statusText = status.map { " status=\($0)" } ?? ""
    print("⏱️ [\(localEngine)] \(operation) \(String(format: "%.2f", duration))s\(statusText)")
  }

  func generateActivityCards(
    observations: [Observation], context: ActivityGenerationContext, batchId: Int64?
  ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
    try TimelineEvidencePolicy.requireVisibleContext(context, observations: observations)
    let callStart = Date()
    let prompt = CodexProvider().buildCardsPrompt(observations: observations, context: context)
    let output = try await callTextAPI(prompt, operation: "generate_cards", expectJSON: true, batchId: batchId)
    let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    let decoded = try JSONDecoder().decode([ActivityCardData].self, from: Data(clean.utf8))
    let cards = TimelineOutputPolicy().normalizeCards(decoded, descriptors: context.categories)
    try ClaudeOutputValidator.validateActivityCards(cards, existingCards: context.existingCards,
      observations: observations)
    return (cards, LLMCall(timestamp: callStart, latency: Date().timeIntervalSince(callStart),
      input: prompt, output: output))
  }

  private func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
    return TimelineOutputPolicy().normalizeCategory(raw, descriptors: categories)
  }

  func parseJSONResponse<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    // First try direct parsing
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      // Try to extract JSON from the response
      guard let responseString = String(data: data, encoding: .utf8) else {
        throw error
      }

      // Look for JSON object
      // A garbled reply can put its last "}" before its first "{"; slicing that
      // range traps at runtime, so only slice when the bounds are ordered.
      if let startIndex = responseString.firstIndex(of: "{"),
        let endIndex = responseString.lastIndex(of: "}"),
        startIndex <= endIndex
      {
        let jsonSubstring = responseString[startIndex...endIndex]
        if let jsonData = jsonSubstring.data(using: .utf8) {
          return try JSONDecoder().decode(type, from: jsonData)
        }
      }

      throw error
    }
  }

  func formatTimestampForPrompt(_ timestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  private func calculateDurationInMinutes(from startTime: String, to endTime: String) -> Int {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    guard let start = formatter.date(from: startTime),
      let end = formatter.date(from: endTime)
    else {
      return 0
    }

    var duration = end.timeIntervalSince(start)

    // Handle day boundary - if end is before start, assume it's the next day
    if duration < 0 {
      duration += 24 * 60 * 60  // Add 24 hours in seconds
    }

    return Int(duration / 60)
  }
}
