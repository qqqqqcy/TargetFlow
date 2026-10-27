import Foundation

enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case codexCLI, claudeCLI, gemini, openAICompatible, local, hosted

  var id: String { rawValue }
  var displayName: String {
    switch self {
    case .codexCLI: return "Codex CLI"
    case .claudeCLI: return "Claude CLI"
    case .gemini: return "Gemini API"
    case .openAICompatible: return String(localized: "API connection")
    case .local: return String(localized: "Local model")
    case .hosted: return String(localized: "Hosted service")
    }
  }

  var providerID: LLMProviderID {
    switch self {
    case .codexCLI: return .chatGPT
    case .claudeCLI: return .claude
    case .gemini: return .gemini
    case .openAICompatible: return .openAICompatible
    case .local: return .local
    case .hosted: return .dayflow
    }
  }
}

struct AIConfiguredModel: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var name: String
  /// nil means the provider has not supplied this capability, not that it is unsupported.
  var reasoningChoices: [String]?
  var supportsReasoning: Bool?
  var supportsVision: Bool?

  init(
    id: String, name: String? = nil, reasoningChoices: [String]? = nil,
    supportsReasoning: Bool? = nil, supportsVision: Bool? = nil
  ) {
    self.id = id
    self.name = name ?? id
    self.reasoningChoices = reasoningChoices
    self.supportsReasoning = supportsReasoning
    self.supportsVision = supportsVision
  }
}

struct AIProviderConnection: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var kind: AIProviderKind
  var endpoint: String?
  var enabled: Bool
  var models: [AIConfiguredModel]
  /// Local connections default to Ollama. "lmstudio" uses its OpenAI-compatible endpoint.
  var localEngine: String?

  init(
    id: UUID = UUID(), name: String, kind: AIProviderKind, endpoint: String? = nil,
    enabled: Bool = true, models: [AIConfiguredModel] = [], localEngine: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.endpoint = endpoint
    self.enabled = enabled
    self.models = models
    self.localEngine = localEngine
  }

  /// Only this identifier is persisted; credentials are stored separately in the local credential directory.
  var secretKeyID: String { "ai.connection.\(id.uuidString.lowercased())" }
}

enum AIFeature: String, Codable, CaseIterable, Identifiable, Sendable {
  case timeline, transcription, activityCards, chat, text, targetEvaluation, dailyRecap, flow

  /// Features exposed by the current app. Other saved routes remain available to legacy runtimes.
  static let configurableCases: [AIFeature] = [.timeline, .targetEvaluation]

  var id: String { rawValue }
  var displayName: String {
    switch self {
    case .timeline: return String(localized: "Timeline")
    case .transcription: return String(localized: "Transcription")
    case .activityCards: return String(localized: "Activity cards")
    case .chat: return String(localized: "Chat")
    case .text: return String(localized: "Text generation")
    case .targetEvaluation: return String(localized: "Target evaluation")
    case .dailyRecap: return String(localized: "Daily recap")
    case .flow: return String(localized: "Flow")
    }
  }
}

struct AIModelAssignment: Codable, Equatable, Hashable, Sendable {
  var connectionID: UUID
  var modelID: String
  /// nil explicitly leaves reasoning effort to the provider.
  var effort: String?

  init(connectionID: UUID, modelID: String, effort: String? = nil) {
    self.connectionID = connectionID
    self.modelID = modelID
    self.effort = effort
  }
}

struct AIFeatureRoute: Codable, Equatable, Sendable {
  var primary: AIModelAssignment
  var fallbacks: [AIModelAssignment]

  init(primary: AIModelAssignment, fallbacks: [AIModelAssignment] = []) {
    self.primary = primary
    self.fallbacks = fallbacks
  }
}

struct AIRuntimeSelection: Equatable, Sendable {
  var connection: AIProviderConnection
  var modelID: String
  var effort: String?

  init(connection: AIProviderConnection, modelID: String, effort: String? = nil) {
    self.connection = connection
    self.modelID = modelID
    self.effort = effort
  }
}

enum AIRequestContext {
  @TaskLocal static var assignment: AIRuntimeSelection? = nil
}

struct AIConfiguration: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
  var schemaVersion: Int = currentSchemaVersion
  var connections: [AIProviderConnection]
  var routes: [AIFeature: AIFeatureRoute]
  var defaultModel: AIModelAssignment?

  init(connections: [AIProviderConnection] = [], routes: [AIFeature: AIFeatureRoute] = [:], defaultModel: AIModelAssignment? = nil) {
    self.connections = connections
    self.routes = routes
    self.defaultModel = defaultModel
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, connections, routes, defaultModel
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    connections = try values.decode([AIProviderConnection].self, forKey: .connections)
    routes = try values.decode([AIFeature: AIFeatureRoute].self, forKey: .routes)
    // A missing key identifies the old schema. An explicit null preserves a cleared default.
    defaultModel = values.contains(.defaultModel)
      ? try values.decodeIfPresent(AIModelAssignment.self, forKey: .defaultModel)
      : routes[.timeline]?.primary
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(connections, forKey: .connections)
    try values.encode(routes, forKey: .routes)
    try values.encode(defaultModel, forKey: .defaultModel)
  }

  /// An explicit feature model is tried first; the shared default is the only fallback.
  /// Legacy per-feature fallback arrays remain decodable but never affect execution.
  func assignments(for feature: AIFeature) -> [AIModelAssignment] {
    var seen = Set<AIModelAssignment>()
    return [routes[feature]?.primary, defaultModel].compactMap { $0 }
      .filter { seen.insert($0).inserted }
  }

  func selection(for assignment: AIModelAssignment) throws -> AIRuntimeSelection {
    guard let connection = connections.first(where: { $0.id == assignment.connectionID }) else {
      throw AIConfigurationError.missingConnection
    }
    guard connection.enabled else { throw AIConfigurationError.disabledConnection }
    try Self.validate(assignment, connection: connection)
    return AIRuntimeSelection(
      connection: connection, modelID: assignment.modelID, effort: assignment.effort)
  }

  func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw AIConfigurationError.unsupportedSchemaVersion(schemaVersion)
    }
    guard Set(connections.map(\.id)).count == connections.count else {
      throw AIConfigurationError.duplicateConnection
    }
    for connection in connections {
      guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIConfigurationError.invalidConnectionName
      }
      if let endpoint = connection.endpoint, !endpoint.isEmpty {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
          ["https", "http"].contains(scheme),
          url.host != nil, url.user == nil, url.password == nil
        else { throw AIConfigurationError.invalidEndpoint }
        let credentialParameters = ["key", "api_key", "apikey", "token", "access_token"]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          items.contains(where: { credentialParameters.contains($0.name.lowercased()) }) {
          throw AIConfigurationError.invalidEndpoint
        }
      }
      guard Set(connection.models.map(\.id)).count == connection.models.count else {
        throw AIConfigurationError.duplicateModel
      }
      for model in connection.models {
        guard Self.isValidIdentifier(model.id) else { throw AIConfigurationError.invalidModel }
      }
    }
    let activeAssignments = routes.values.map(\.primary) + [defaultModel].compactMap { $0 }
    for assignment in activeAssignments {
      guard let connection = connections.first(where: { $0.id == assignment.connectionID }) else {
        throw AIConfigurationError.missingConnection
      }
      // Disabled connections remain saved so users can temporarily pause a connection.
      try Self.validate(assignment, connection: connection)
    }
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private static func validate(_ assignment: AIModelAssignment, connection: AIProviderConnection) throws {
    guard isValidIdentifier(assignment.modelID) else { throw AIConfigurationError.invalidModel }
    if let effort = assignment.effort {
      guard isValidIdentifier(effort) else { throw AIConfigurationError.invalidEffort }
      if let model = connection.models.first(where: { $0.id == assignment.modelID }) {
        if model.supportsReasoning == false { throw AIConfigurationError.invalidEffort }
        if let choices = model.reasoningChoices, !choices.contains(effort) {
          throw AIConfigurationError.invalidEffort
        }
      }
    }
  }
}

enum AIConfigurationError: LocalizedError, Equatable {
  case corruptStoredValue, unsupportedSchemaVersion(Int), writeVerificationFailed, credentialWriteFailed
  case duplicateConnection, duplicateModel, missingConnection, disabledConnection
  case invalidConnectionName, invalidEndpoint, invalidModel, invalidEffort

  var errorDescription: String? {
    switch self {
    case .corruptStoredValue: return String(localized: "The saved AI configuration could not be read.")
    case .unsupportedSchemaVersion: return String(localized: "This AI configuration was saved by a newer app version.")
    case .writeVerificationFailed: return String(localized: "The AI configuration could not be saved.")
    case .credentialWriteFailed: return String(localized: "The connection credential could not be saved locally.")
    case .duplicateConnection: return String(localized: "Each connection must have a unique identifier.")
    case .duplicateModel: return String(localized: "Each model in a connection must have a unique identifier.")
    case .missingConnection: return String(localized: "The selected connection no longer exists.")
    case .disabledConnection: return String(localized: "The selected connection is disabled.")
    case .invalidConnectionName: return String(localized: "Enter a connection name.")
    case .invalidEndpoint: return String(localized: "Enter an HTTP or HTTPS endpoint without embedded credentials.")
    case .invalidModel: return String(localized: "Enter a model identifier without control characters.")
    case .invalidEffort: return String(localized: "The selected reasoning effort is not supported by this model.")
    }
  }
}

/// A single lock serializes reads, first-run migration, and writes across store instances.
final class AIConfigurationStore: @unchecked Sendable {
  static let shared = AIConfigurationStore()
  static let storageKey = "aiConfiguration.v1"
  private static let lock = NSLock()
  private let defaults: UserDefaults
  private let readSecret: (String) -> String?
  private let writeSecret: (String, String) -> Bool
  private let deleteSecret: (String) -> Bool

  init(
    defaults: UserDefaults = .standard,
    readSecret: @escaping (String) -> String? = { LocalProviderCredentialStore.shared.retrieve(for: $0) },
    writeSecret: @escaping (String, String) -> Bool = { LocalProviderCredentialStore.shared.store($0, for: $1) },
    deleteSecret: @escaping (String) -> Bool = { LocalProviderCredentialStore.shared.delete(for: $0) }
  ) {
    self.defaults = defaults
    self.readSecret = readSecret
    self.writeSecret = writeSecret
    self.deleteSecret = deleteSecret
  }

  func load() throws -> AIConfiguration {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    if defaults.object(forKey: Self.storageKey) != nil {
      guard let data = defaults.data(forKey: Self.storageKey),
        var configuration = try? JSONDecoder().decode(AIConfiguration.self, from: data)
      else { throw AIConfigurationError.corruptStoredValue }
      let oldPresetNames: [String: String] = [
        "OpenAI（兼容 API）": "OpenAI", "OpenAI (compatible API)": "OpenAI",
        "DeepSeek（兼容 API）": "DeepSeek", "DeepSeek (compatible API)": "DeepSeek",
        "Kimi（兼容 API）": "Kimi", "Kimi (compatible API)": "Kimi",
      ]
      var renamed = false
      for index in configuration.connections.indices {
        if let name = oldPresetNames[configuration.connections[index].name] {
          configuration.connections[index].name = name
          renamed = true
        }
      }
      try configuration.validate()
      if renamed { try saveLocked(configuration) }
      return configuration
    }
    let configuration = try migrateLegacy()
    try saveLocked(configuration)
    if let oldLocalSecret = defaults.string(forKey: "llmLocalAPIKey"),
      let local = configuration.connections.first(where: { $0.kind == .local }),
      readSecret(local.secretKeyID) == oldLocalSecret.trimmingCharacters(in: .whitespacesAndNewlines) {
      // Remove the legacy plaintext only after both credential and configuration writes succeed.
      defaults.removeObject(forKey: "llmLocalAPIKey")
    }
    return configuration
  }

  func save(_ configuration: AIConfiguration) throws {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    try saveLocked(configuration)
  }

  func secret(for connection: AIProviderConnection) -> String? {
    readSecret(connection.secretKeyID)
  }

  func saveSecret(_ secret: String, for connection: AIProviderConnection) throws {
    let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    let success = value.isEmpty ? deleteSecret(connection.secretKeyID) : writeSecret(value, connection.secretKeyID)
    guard success else { throw AIConfigurationError.credentialWriteFailed }
  }

  private func saveLocked(_ configuration: AIConfiguration) throws {
    try configuration.validate()
    let data = try JSONEncoder().encode(configuration)
    let previous = defaults.object(forKey: Self.storageKey)
    defaults.set(data, forKey: Self.storageKey)
    guard defaults.data(forKey: Self.storageKey) == data else {
      if let previous { defaults.set(previous, forKey: Self.storageKey) }
      else { defaults.removeObject(forKey: Self.storageKey) }
      throw AIConfigurationError.writeVerificationFailed
    }
  }

  private func migrateLegacy() throws -> AIConfiguration {
    // Read legacy artifacts without invoking legacy load functions that rewrite preferences.
    let legacy = LegacyLLMProviderMigration.migrate(from: defaults)
    let routing: LLMProviderRouting
    if let data = defaults.data(forKey: LLMProviderRoutingStore.storageKey) {
      guard let stored = try? JSONDecoder().decode(LLMProviderRouting.self, from: data),
        stored.schemaVersion == LLMProviderRouting.currentSchemaVersion
      else { throw AIConfigurationError.corruptStoredValue }
      routing = stored
    } else {
      routing = legacy.routing
    }
    let compatible = OpenAICompatiblePreferences.load(from: defaults)
    let geminiPreference = defaults.data(forKey: "geminiSelectedModel_v5")
      .flatMap { try? JSONDecoder().decode(GeminiModelPreference.self, from: $0) }
      ?? .default
    var configuration = AIConfiguration()
    var byProvider: [LLMProviderID: AIProviderConnection] = [:]
    let dailyRaw = defaults.string(forKey: "dailyRecapProvider_v1")
    let dailyProvider = dailyRaw.flatMap { LLMProviderID(rawValue: $0) }
    for kind in AIProviderKind.allCases {
      let provider = kind.providerID
      let oldSecretID: String?
      switch kind {
      case .gemini: oldSecretID = "gemini"
      case .openAICompatible: oldSecretID = OpenAICompatiblePreferences.keychainProvider
      case .hosted: oldSecretID = "dayflow"
      default: oldSecretID = nil
      }
      let oldSecret = oldSecretID.flatMap(readSecret)
      let hasPreferences = defaults.object(forKey: ModelPreferences.storageKey(for: provider)) != nil
      let selected = routing.primary == provider || routing.secondary == provider || dailyProvider == provider
      let configured = selected || hasPreferences || (oldSecret?.isEmpty == false)
        || LLMProviderSetupPreferences.isComplete(provider, in: defaults)
        || (kind == .local && (defaults.string(forKey: "llmLocalModelId") != nil || defaults.bool(forKey: "ollamaSetupComplete")))
        || (kind == .openAICompatible && compatible != nil)
      guard configured else { continue }
      // Fixed UUIDs make retries and independent migration runs deterministic.
      let suffix = String(format: "%012d", AIProviderKind.allCases.firstIndex(of: kind)! + 1)
      var connection = AIProviderConnection(
        id: UUID(uuidString: "A1C00000-0000-4000-8000-\(suffix)")!, name: kind.displayName, kind: kind)
      switch kind {
      case .gemini: connection.endpoint = "https://generativelanguage.googleapis.com/v1beta"
      case .openAICompatible: connection.endpoint = compatible?.baseURL
      case .local:
        connection.endpoint = defaults.string(forKey: "llmLocalBaseURL") ?? legacy.localEndpointOverride ?? "http://localhost:11434"
        connection.localEngine = defaults.string(forKey: "llmLocalEngine") ?? "ollama"
      case .hosted:
        connection.endpoint = defaults.string(forKey: "dayflowProviderEndpointV2") ?? legacy.dayflowEndpointOverride
      default: break
      }
      let preferences = ModelPreferences.load(provider: provider, from: defaults)
      var models: [String] = [preferences.defaultSelection.model]
        + preferences.featureOverrides.values.map(\.model) + (preferences.fallbackModels ?? [])
      for feature in AIFeature.allCases {
        models.append(legacySelection(provider: provider, feature: feature, preferences: preferences,
          compatible: compatible, gemini: geminiPreference, connectionID: connection.id).modelID)
      }
      var seen = Set<String>()
      connection.models = models.filter { !$0.isEmpty && seen.insert($0).inserted }
        .map { AIConfiguredModel(id: $0) }
      if let secret = oldSecret, !secret.isEmpty {
        try saveSecret(secret, for: connection)
      } else if kind == .local, let secret = defaults.string(forKey: "llmLocalAPIKey"), !secret.isEmpty {
        try saveSecret(secret, for: connection)
      }
      byProvider[provider] = connection
      configuration.connections.append(connection)
    }
    for feature in AIFeature.allCases {
      if feature == .dailyRecap && dailyRaw == "none" { continue }
      let provider = feature == .dailyRecap ? (dailyProvider ?? routing.primary) : routing.primary
      guard let connection = byProvider[provider] else { continue }
      let preferences = ModelPreferences.load(provider: provider, from: defaults)
      // An absent stage override preserves the existing one-step timeline pipeline.
      if feature == .transcription || feature == .activityCards {
        guard let oldFeature = ModelFeature(rawValue: feature.rawValue),
          preferences.featureOverrides[oldFeature] != nil else { continue }
      }
      let primary = legacySelection(provider: provider, feature: feature, preferences: preferences,
        compatible: compatible, gemini: geminiPreference, connectionID: connection.id)
      guard !primary.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let fallbackModels = preferences.fallbackModels
      var fallbacks = (fallbackModels ?? []).filter { $0 != primary.modelID }.map {
        AIModelAssignment(connectionID: connection.id, modelID: $0, effort: primary.effort)
      }
      if feature != .dailyRecap, let secondary = routing.secondary, let backup = byProvider[secondary] {
        let backupPreferences = ModelPreferences.load(provider: secondary, from: defaults)
        let fallback = legacySelection(provider: secondary, feature: feature, preferences: backupPreferences,
          compatible: compatible, gemini: geminiPreference, connectionID: backup.id)
        if !fallback.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          fallbacks.append(fallback)
        }
      }
      configuration.routes[feature] = AIFeatureRoute(primary: primary, fallbacks: fallbacks)
    }
    configuration.defaultModel = configuration.routes[.timeline]?.primary
    return configuration
  }

  private func legacySelection(
    provider: LLMProviderID, feature: AIFeature, preferences: ModelPreferences,
    compatible: OpenAICompatibleConfiguration?, gemini: GeminiModelPreference, connectionID: UUID
  ) -> AIModelAssignment {
    let model: String
    let effort: String?
    switch provider {
    case .chatGPT:
      (model, effort) = feature == .flow
        ? (defaults.string(forKey: "flowAgentModel") ?? "", defaults.string(forKey: "flowAgentReasoning"))
        : ("", nil)
    case .claude: (model, effort) = ("", nil)
    case .gemini:
      (model, effort) = defaults.object(forKey: "geminiSelectedModel_v5") != nil
        ? (gemini.primary.rawValue, nil) : ("", nil)
    case .openAICompatible: (model, effort) = (compatible?.modelID ?? "", nil)
    case .local:
      let stored = defaults.string(forKey: "llmLocalModelId") ?? ""
      (model, effort) = (stored, nil)
    case .dayflow: (model, effort) = ("", nil)
    }
    let oldFeature = ModelFeature(rawValue: feature.rawValue) ?? .text
    let resolved = preferences.resolve(provider: provider, feature: oldFeature,
      defaultModel: model, defaultEffort: effort)
    return AIModelAssignment(connectionID: connectionID,
      modelID: resolved.model, effort: resolved.reasoningEffort)
  }
}
