//
//  GeminiDirectProvider.swift
//  Dayflow
//

import Foundation

final class GeminiDirectProvider {
  let apiKey: String
  let fileEndpoint = "https://generativelanguage.googleapis.com/upload/v1beta/files"
  let modelPreference: GeminiModelPreference

  static let capacityErrorCodes: Set<Int> = [403, 404, 429, 503]

  struct ModelRunState {
    let models: [String]
    private(set) var index: Int = 0

    init(models: [String]) {
      self.models = models.isEmpty ? GeminiModelPreference.default.orderedModels.map(\.rawValue) : models
    }

    var current: String {
      models[min(index, models.count - 1)]
    }

    mutating func advance() -> (from: String, to: String)? {
      guard index < models.count - 1 else { return nil }
      let fromModel = models[index]
      index += 1
      return (fromModel, models[index])
    }
  }

  func endpointForModel(_ model: String) -> String {
    return
      "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
  }

  func selectedModels(feature: ModelFeature, defaults: UserDefaults = .standard) -> [String] {
    if let assignment = AIRequestContext.assignment { return [assignment.modelID] }
    let legacy = (feature == .chat ? Self.dashboardChatModels : modelPreference.orderedModels)
      .map(\.rawValue)
    let selection = ModelPreferences.resolve(
      provider: .gemini, feature: feature, defaultModel: legacy[0], defaultEffort: "high",
      defaults: defaults)
    let fallbacks = ModelPreferences.load(provider: .gemini, from: defaults).fallbackModels
      ?? Array(legacy.dropFirst())
    var seen = Set<String>()
    return ([selection.model] + fallbacks).filter { seen.insert($0).inserted }
  }

  func thinkingConfig(
    feature: ModelFeature, model: String, defaults: UserDefaults = .standard
  ) throws -> [String: Any]? {
    if let assignment = AIRequestContext.assignment {
      // The configuration validates reported capabilities; do not guess support
      // from model names or reject future provider-defined effort values.
      guard let effort = assignment.effort, effort != "default" else { return nil }
      return ["thinkingLevel": effort]
    }
    let effort = ModelPreferences.resolve(
      provider: .gemini, feature: feature, defaultModel: model, defaultEffort: "high",
      defaults: defaults).reasoningEffort
    guard let effort, effort != "default" else { return nil }
    let preferences = ModelPreferences.load(provider: .gemini, from: defaults)
    let explicit = preferences.featureOverrides[feature]?.reasoningEffort
      ?? preferences.defaultSelection.reasoningEffort
    let supported: [String]
    if model.hasPrefix("gemini-3"), model.contains("flash") {
      supported = ["minimal", "low", "medium", "high"]
    } else if model.hasPrefix("gemini-3"), model.contains("pro") {
      supported = ["low", "high"]
    } else {
      supported = []
    }
    if explicit != nil || AIRequestContext.assignment != nil, !supported.contains(effort) {
      throw NSError(domain: "GeminiModelPreferences", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "The selected Gemini model does not support thinking level \(effort)."
      ])
    }
    if model.hasPrefix("gemini-2.5") { return nil }
    guard ["minimal", "low", "medium", "high"].contains(effort) else { return nil }
    return ["thinkingLevel": effort]
  }

  func recordResponse(
    _ data: Data, model: String, feature: ModelFeature, startedAt: Date, status: Int?
  ) {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let config = try? thinkingConfig(feature: feature, model: model)
    let requestedReasoning = config?["thinkingLevel"] as? String
    let reported = json?["modelVersion"] as? String
    if let reported { print("Gemini response model: \(reported) (requested: \(model))") }
    ModelExecutionHistory.shared.record(
      provider: LLMProviderID.gemini.rawValue, requestedModel: model,
      reportedModels: reported.map { [$0] } ?? [],
      requestedReasoning: requestedReasoning,
      startedAt: startedAt, outcome: status.map { (200...299).contains($0) } == true ? .succeeded : .failed,
      failureCode: status.flatMap { (200...299).contains($0) ? nil : "HTTP \($0)" })
  }

  init(apiKey: String, preference: GeminiModelPreference = .default) {
    self.apiKey = apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
    self.modelPreference = preference
  }
}
