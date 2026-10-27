import Foundation

struct ActivityCardPromptOverrides: Codable, Equatable {
  var titleBlock: String?
  var summaryBlock: String?
  var detailedBlock: String?

  var isEmpty: Bool {
    [titleBlock, summaryBlock, detailedBlock].allSatisfy {
      ($0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
  }

  /// Explicitly scoped additions preserve each provider's schema and factual requirements.
  var instructionBlock: String {
    let sections = [("Card titles", titleBlock), ("Card summaries", summaryBlock),
      ("Detailed summaries", detailedBlock)].compactMap { heading, value -> String? in
      guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
      }
      return "### \(heading)\n\(text)"
    }
    guard !sections.isEmpty else { return "" }
    return """
      ## Custom activity-card instructions
      Apply these preferences to the named fields, taking precedence over default writing style. Preserve the required output schema, timestamps, coverage, and evidence constraints.

      \(sections.joined(separator: "\n\n"))
      """
  }
}

enum ProviderPromptPreferencesError: Error {
  case encodingFailed
  case writeVerificationFailed
}

/// One preference set for every configured provider. Legacy stores remain untouched.
enum ActivityCardPromptPreferences {
  static let storageKey = "activityCardPromptOverrides.v1"
  private static let lock = NSLock()

  static func load(from defaults: UserDefaults = .standard) -> ActivityCardPromptOverrides {
    lock.lock()
    defer { lock.unlock() }
    if defaults.object(forKey: storageKey) != nil {
      return decode(storageKey, from: defaults) ?? ActivityCardPromptOverrides()
    }
    let migrated = migrate(from: defaults)
    // Persist even an empty result: resetting must never resurrect legacy preferences.
    if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: storageKey) }
    return migrated
  }

  static func saveVerified(
    _ overrides: ActivityCardPromptOverrides, to defaults: UserDefaults = .standard
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let previous = defaults.object(forKey: storageKey)
    let data: Data
    do { data = try JSONEncoder().encode(overrides) }
    catch { throw ProviderPromptPreferencesError.encodingFailed }
    defaults.set(data, forKey: storageKey)
    guard decode(storageKey, from: defaults) == overrides else {
      if let previous { defaults.set(previous, forKey: storageKey) }
      else { defaults.removeObject(forKey: storageKey) }
      throw ProviderPromptPreferencesError.writeVerificationFailed
    }
  }

  static func reset(in defaults: UserDefaults = .standard) {
    try? saveVerified(ActivityCardPromptOverrides(), to: defaults)
  }

  private static func decode(_ key: String, from defaults: UserDefaults) -> ActivityCardPromptOverrides? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(ActivityCardPromptOverrides.self, from: data)
  }

  private static func migrate(from defaults: UserDefaults) -> ActivityCardPromptOverrides {
    let keys: [AIProviderKind: String] = [
      .codexCLI: "chatGPTPromptOverrides", .claudeCLI: "claudePromptOverrides",
      .gemini: "geminiPromptOverrides", .local: "ollamaPromptOverrides",
      .openAICompatible: "chatGPTPromptOverrides", .hosted: "geminiPromptOverrides",
    ]
    var preferred: String?
    if let data = defaults.data(forKey: AIConfigurationStore.storageKey),
      let configuration = try? JSONDecoder().decode(AIConfiguration.self, from: data) {
      for assignment in configuration.assignments(for: .timeline) {
        if let selection = try? configuration.selection(for: assignment) {
          preferred = keys[selection.connection.kind]
          break
        }
      }
    }
    if preferred == nil {
      let routing = defaults.data(forKey: LLMProviderRoutingStore.storageKey)
        .flatMap { try? JSONDecoder().decode(LLMProviderRouting.self, from: $0) }
        ?? LegacyLLMProviderMigration.migrate(from: defaults).routing
      switch routing.primary {
      case .chatGPT, .openAICompatible: preferred = "chatGPTPromptOverrides"
      case .claude: preferred = "claudePromptOverrides"
      case .gemini, .dayflow: preferred = "geminiPromptOverrides"
      case .local: preferred = "ollamaPromptOverrides"
      }
    }
    // An explicitly saved empty active set also represents the user's preference.
    if let preferred, let value = decode(preferred, from: defaults) { return value }
    // Select a whole preference set; do not mix conflicting fields from different providers.
    let order = [preferred].compactMap { $0 } + [
      "chatGPTPromptOverrides", "claudePromptOverrides", "geminiPromptOverrides",
      "ollamaPromptOverrides", "chatCLIPromptOverrides",
    ]
    for key in order {
      if let value = decode(key, from: defaults), !value.isEmpty { return value }
    }
    return ActivityCardPromptOverrides()
  }
}
