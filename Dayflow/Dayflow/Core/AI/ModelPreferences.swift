import Foundation

enum ModelFeature: String, Codable, CaseIterable, Identifiable {
  case timeline, transcription, activityCards, chat, text, dailyRecap, flow

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .timeline: return String(localized: "Timeline")
    case .transcription: return String(localized: "Transcription")
    case .activityCards: return String(localized: "Activity cards")
    case .chat: return String(localized: "Chat")
    case .text: return String(localized: "Text generation")
    case .dailyRecap: return String(localized: "Daily recap")
    case .flow: return String(localized: "Flow")
    }
  }
}

enum ModelReasoningEffort: String, Codable, CaseIterable, Identifiable {
  /// Explicitly omit the effort parameter. A nil override instead inherits its parent.
  case providerDefault, none, minimal, low, medium, high, xhigh, max

  var id: String { rawValue }
  var output: String? { self == .providerDefault ? nil : rawValue }
  var displayName: String {
    self == .providerDefault ? String(localized: "Provider default (omit effort)") : rawValue
  }

  static func choices(for provider: LLMProviderID) -> [Self] {
    switch provider {
    case .chatGPT: return [.providerDefault, .none, .minimal, .low, .medium, .high, .xhigh]
    case .openAICompatible: return allCases
    case .claude: return [.providerDefault, .low, .medium, .high, .max]
    case .gemini: return [.providerDefault, .minimal, .low, .medium, .high]
    case .local, .dayflow: return [.providerDefault]
    }
  }

  static func choices(for provider: LLMProviderID, model: String) -> [Self] {
    guard provider == .gemini else { return choices(for: provider) }
    let model = model.lowercased()
    if model.isEmpty { return choices(for: provider) }
    guard model.hasPrefix("gemini-3") else { return [.providerDefault] }
    return model.contains("pro") ? [.providerDefault, .low, .high] : choices(for: provider)
  }
}

struct ModelSelection: Equatable {
  let model: String
  let reasoningEffort: String?

  var tuple: (model: String, reasoningEffort: String?) { (model, reasoningEffort) }
}

struct ModelOverride: Codable, Equatable {
  var model: String = ""
  var reasoningEffort: ModelReasoningEffort? = nil
}

enum ModelPreferencesError: LocalizedError {
  case unsupportedEffort(ModelReasoningEffort)
  case invalidModel
  case writeVerificationFailed

  var errorDescription: String? {
    switch self {
    case .unsupportedEffort(let effort):
      return String(localized: "The selected provider or model does not support reasoning effort ‘\(effort.rawValue)’.")
    case .invalidModel:
      return String(localized: "Model names must be single lines without control characters.")
    case .writeVerificationFailed:
      return String(localized: "Model preferences could not be saved. Please try again.")
    }
  }
}

struct ModelPreferences: Codable, Equatable {
  var defaultSelection: ModelOverride = ModelOverride()
  var featureOverrides: [ModelFeature: ModelOverride] = [:]
  /// nil preserves the existing provider cascade; [] explicitly disables model fallback.
  var fallbackModels: [String]? = nil

  static func storageKey(for provider: LLMProviderID) -> String {
    "modelPreferences.v1.\(provider.rawValue)"
  }

  static func load(provider: LLMProviderID, from defaults: UserDefaults = .standard)
    -> ModelPreferences
  {
    guard let data = defaults.data(forKey: storageKey(for: provider)),
      let value = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return value.normalized
  }

  func save(provider: LLMProviderID, to defaults: UserDefaults = .standard) throws {
    let value = normalized
    try value.validate(provider: provider)
    let data = try JSONEncoder().encode(value)
    let key = Self.storageKey(for: provider)
    let previous = defaults.object(forKey: key)
    defaults.set(data, forKey: key)
    guard defaults.data(forKey: key) == data else {
      if let previous { defaults.set(previous, forKey: key) }
      else { defaults.removeObject(forKey: key) }
      throw ModelPreferencesError.writeVerificationFailed
    }
  }

  func validate(provider: LLMProviderID) throws {
    let selections = [defaultSelection] + Array(featureOverrides.values)
    for selection in selections {
      let model = selection.model.isEmpty ? defaultSelection.model : selection.model
      let choices = ModelReasoningEffort.choices(for: provider, model: model)
      if let effort = selection.reasoningEffort ?? defaultSelection.reasoningEffort,
        !choices.contains(effort)
      {
        throw ModelPreferencesError.unsupportedEffort(effort)
      }
    }
    for model in selections.map(\.model) + (fallbackModels ?? []) {
      if model.rangeOfCharacter(from: .controlCharacters) != nil {
        throw ModelPreferencesError.invalidModel
      }
    }
  }

  static func resolve(
    provider: LLMProviderID,
    feature: ModelFeature,
    defaultModel: String,
    defaultEffort: String?,
    defaults: UserDefaults = .standard
  ) -> ModelSelection {
    if let assignment = AIRequestContext.assignment {
      return ModelSelection(model: assignment.modelID, reasoningEffort: assignment.effort)
    }
    return load(provider: provider, from: defaults).resolve(
      provider: provider, feature: feature, defaultModel: defaultModel, defaultEffort: defaultEffort)
  }

  func resolve(
    provider: LLMProviderID, feature: ModelFeature, defaultModel: String, defaultEffort: String?
  ) -> ModelSelection {
    let value = normalized
    let featureSelection = value.featureOverrides[feature] ?? ModelOverride()
    let model = !featureSelection.model.isEmpty ? featureSelection.model
      : (!value.defaultSelection.model.isEmpty ? value.defaultSelection.model : defaultModel)
    var effort = defaultEffort
    for selection in [value.defaultSelection, featureSelection] {
      if let override = selection.reasoningEffort,
        ModelReasoningEffort.choices(for: provider).contains(override)
      {
        effort = override.output
      }
    }
    return ModelSelection(model: model, reasoningEffort: effort)
  }

  private var normalized: Self {
    var value = self
    value.defaultSelection.model = Self.trim(defaultSelection.model)
    value.featureOverrides = featureOverrides.mapValues {
      var selection = $0
      selection.model = Self.trim(selection.model)
      return selection
    }
    if let models = fallbackModels {
      var seen: Set<String> = []
      value.fallbackModels = models.map(Self.trim).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    return value
  }

  private static func trim(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func recommendedModels(for provider: LLMProviderID) -> [String] {
    switch provider {
    case .chatGPT: return ["gpt-6-luna", "gpt-6.1-sol"]
    case .claude: return ["haiku", "sonnet", "opus"]
    case .gemini: return GeminiModel.allCases.map(\.rawValue)
    case .local, .openAICompatible, .dayflow: return []
    }
  }
}
