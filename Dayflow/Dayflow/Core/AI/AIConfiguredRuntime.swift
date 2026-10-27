import Foundation

/// The only providers a saved connection can construct. Construction never consults legacy credentials.
enum AIConfiguredProvider: @unchecked Sendable {
  case codex(CodexProvider)
  case claude(ClaudeProvider)
  case gemini(GeminiDirectProvider)
  case compatible(OpenAICompatibleProvider)
  case local(OllamaProvider)
  case hosted(DayflowBackendProvider)

  func generateText(prompt: String, feature: AIFeature = .text) async throws -> (text: String, log: LLMCall) {
    switch self {
    case .codex(let provider):
      guard let selected = AIRequestContext.assignment else { throw AIConfiguredRuntimeError.invalidSelection }
      return try await provider.generateText(prompt: prompt, model: selected.modelID, reasoningEffort: selected.effort, disableTools: feature == .targetEvaluation)
    case .claude(let provider):
      guard let selected = AIRequestContext.assignment else { throw AIConfiguredRuntimeError.invalidSelection }
      return try await provider.generateText(prompt: prompt, model: selected.modelID, reasoningEffort: selected.effort, disableTools: feature == .targetEvaluation)
    case .gemini(let provider): return try await provider.generateText(prompt: prompt, feature: feature.modelFeature)
    case .compatible(let provider): return try await provider.generateText(prompt: prompt, feature: feature.modelFeature)
    case .local(let provider): return try await provider.generateText(prompt: prompt, feature: feature.modelFeature)
    case .hosted(let provider): return try await provider.generateText(prompt: prompt)
    }
  }

  /// Reuses the configured transports. Gemini's existing vision transcription runs before the text turn.
  func imageText(prompt: String, imageURLs: [URL], feature: AIFeature = .flow) async throws -> String {
    guard let selection = AIRequestContext.assignment, !imageURLs.isEmpty else {
      throw AIConfiguredRuntimeError.invalidSelection
    }
    switch self {
    case .compatible, .local:
      guard let endpoint = selection.connection.endpoint else { throw AIConfiguredRuntimeError.invalidEndpoint }
      let transport: OllamaProvider
      if case .local(let provider) = self { transport = provider }
      else {
        transport = OllamaProvider(openAICompatible: OpenAICompatibleRuntimeConfiguration(
          configuration: OpenAICompatibleConfiguration(preset: .custom, baseURL: endpoint, modelID: selection.modelID),
          bearerToken: LocalProviderCredentialStore.shared.retrieve(for: selection.connection.secretKeyID)))
      }
      var content: [OllamaProvider.MessageContent] = [.init(type: "text", text: prompt, image_url: nil)]
      for url in imageURLs {
        let image = try Data(contentsOf: url)
        content.append(.init(type: "image_url", text: nil, image_url: .init(url: "data:image/jpeg;base64,\(image.base64EncodedString())")))
      }
      let request = transport.configuredRequest(.init(model: selection.modelID, messages: [.init(role: "user", content: content)]), feature: feature.modelFeature)
      let response = try await transport.callChatAPI(request, operation: feature == .timeline ? "generate_timeline" : "flow", batchId: nil, maxRetries: 1)
      return response.choices.first?.message.content ?? ""
    case .gemini(let provider):
      return try await provider.generateText(prompt: prompt, feature: feature.modelFeature, imageURLs: imageURLs).text
    default: throw AIConfiguredRuntimeError.unsupportedProvider
    }
  }

  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
    switch self {
    case .codex(let provider): return try await provider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
    case .claude(let provider): return try await provider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
    case .gemini(let provider): return try await provider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
    case .compatible(let provider): return try await provider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
    case .local(let provider): return try await provider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
    case .hosted(let provider): return try await provider.transcribeScreenshots(screenshots, batchStartTime: batchStartTime, batchId: batchId)
    }
  }

  func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], rewriteSpan: Range<Int>?, log: LLMCall) {
    switch self {
    case .claude(let provider): return try await provider.generateActivityCards(observations: observations, context: context, batchId: batchId)
    case .codex(let provider):
      let result = try await provider.generateActivityCards(observations: observations, context: context, batchId: batchId)
      return (result.cards, nil, result.log)
    case .gemini(let provider):
      let result = try await provider.generateActivityCards(observations: observations, context: context, batchId: batchId)
      return (result.cards, nil, result.log)
    case .compatible(let provider):
      let result = try await provider.generateActivityCards(observations: observations, context: context, batchId: batchId)
      return (result.cards, nil, result.log)
    case .local(let provider):
      let result = try await provider.generateActivityCards(observations: observations, context: context, batchId: batchId)
      return (result.cards, nil, result.log)
    case .hosted(let provider):
      let result = try await provider.generateActivityCards(observations: observations, context: context, batchId: batchId)
      return (result.cards, nil, result.log)
    }
  }

  func generateTimeline(screenshots: [Screenshot], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?, log: LLMCall) {
    switch self {
    case .codex(let provider): return try await provider.generateTimeline(screenshots: screenshots, context: context, batchId: batchId)
    case .claude(let provider): return try await provider.generateTimeline(screenshots: screenshots, context: context, batchId: batchId)
    case .hosted(let provider):
      let result = try await provider.generateTimeline(screenshots: screenshots, context: context, batchId: batchId)
      return (result.cards, result.observations, nil, result.log)
    case .compatible(let provider):
      return try await provider.generateTimeline(screenshots: screenshots, context: context, batchId: batchId)
    case .local, .gemini:
      guard let selection = AIRequestContext.assignment else { throw AIConfiguredRuntimeError.invalidSelection }
      let frames = try await OneStepTimelineFrames.write(screenshots, maxHeight: 1080,
        directoryPrefix: "TargetFlow-direct-timeline")
      defer { frames.cleanup() }
      let window = Observation(id: nil, batchId: batchId ?? -1, startTs: frames.windowStart,
        endTs: frames.windowEnd, observation: "", metadata: nil, llmModel: selection.modelID, createdAt: Date())
      let plan = CodexProvider().makeClaudeCardGenerationPlan(observations: [window], context: ActivityGenerationContext(
        batchObservations: [window], existingCards: context.existingCards, currentTime: context.currentTime,
        categories: context.categories, hasPreviousCardWithinFiveMinutes: context.hasPreviousCardWithinFiveMinutes))
      let prompt = CodexProvider().buildTimelinePrompt(frames: frames,
        previousCards: plan.context.existingCards, categories: context.categories)
      let started = Date()
      let output = try await imageText(prompt: prompt, imageURLs: frames.frames.map(\.url), feature: .timeline)
      let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
      let cards = try JSONDecoder().decode([ActivityCardData].self, from: Data(cleaned.utf8))
      try ClaudeOutputValidator.validateActivityCards(cards, existingCards: plan.context.existingCards, observations: [window])
      return (cards, OneStepTimelineObservations.make(from: cards, windowStart: frames.windowStart,
        windowEnd: frames.windowEnd, batchId: batchId, model: selection.modelID), nil,
        LLMCall(timestamp: started, latency: Date().timeIntervalSince(started), input: prompt, output: output))
    }
  }
}

enum AIConfiguredRuntimeError: LocalizedError {
  case missingRoute, invalidSelection, missingSecret, invalidEndpoint, unsupportedProvider, timedOut

  var errorDescription: String? {
    switch self {
    case .missingRoute: return String(localized: "No model is assigned to this feature.")
    case .invalidSelection: return String(localized: "The assigned connection or model is unavailable or disabled.")
    case .missingSecret: return String(localized: "This connection needs an API key in Settings.")
    case .invalidEndpoint: return String(localized: "This connection needs a valid HTTP or HTTPS endpoint.")
    case .unsupportedProvider: return String(localized: "This provider does not support configured execution.")
    case .timedOut: return String(localized: "Validation timed out.")
    }
  }
}

struct AIConfiguredRuntime {
  let configuration: AIConfiguration
  private let secret: (AIProviderConnection) -> String?

  init(configuration: AIConfiguration, secret: @escaping (AIProviderConnection) -> String? = { LocalProviderCredentialStore.shared.retrieve(for: $0.secretKeyID) }) {
    self.configuration = configuration
    self.secret = secret
  }

  static func load() throws -> Self {
    Self(configuration: try AIConfigurationStore.shared.load())
  }

  func selections(for feature: AIFeature) throws -> [AIRuntimeSelection] {
    let assignments = configuration.assignments(for: feature)
    guard !assignments.isEmpty else { throw AIConfiguredRuntimeError.missingRoute }
    return try assignments.map { try selection(for: $0) }
  }

  func selection(for assignment: AIModelAssignment) throws -> AIRuntimeSelection {
    try configuration.selection(for: assignment)
  }

  /// Tries exactly the configured sequence. Cancellation never starts a fallback.
  func withConfiguration<T>(feature: AIFeature, operation: (AIConfiguredProvider) async throws -> T) async throws -> T {
    let assignments = configuration.assignments(for: feature)
    guard !assignments.isEmpty else { throw AIConfiguredRuntimeError.missingRoute }
    var lastError: Error = AIConfiguredRuntimeError.missingRoute
    for assignment in assignments {
      try Task.checkCancellation()
      do {
        return try await withSelection(try selection(for: assignment), operation: operation)
      } catch {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        lastError = error
      }
    }
    throw lastError
  }

  func withSelection<T>(_ selection: AIRuntimeSelection, operation: (AIConfiguredProvider) async throws -> T) async throws -> T {
    try Task.checkCancellation()
    return try await AIRequestContext.$assignment.withValue(selection) {
      try await operation(makeProvider(for: selection))
    }
  }

  func makeProvider(for selection: AIRuntimeSelection) throws -> AIConfiguredProvider {
    let connection = selection.connection
    guard connection.enabled else { throw AIConfiguredRuntimeError.invalidSelection }
    switch connection.kind {
    case .codexCLI: return .codex(CodexProvider())
    case .claudeCLI: return .claude(ClaudeProvider())
    case .gemini:
      guard let token = secret(connection), !token.isEmpty else { throw AIConfiguredRuntimeError.missingSecret }
      return .gemini(GeminiDirectProvider(apiKey: token))
    case .openAICompatible, .local:
      guard let endpoint = connection.endpoint, let url = URL(string: endpoint),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
        url.user == nil, url.password == nil
      else { throw AIConfiguredRuntimeError.invalidEndpoint }
      let configured = OpenAICompatibleRuntimeConfiguration(
        configuration: OpenAICompatibleConfiguration(preset: .custom, baseURL: endpoint, modelID: selection.modelID),
        bearerToken: secret(connection), analyticsProvider: connection.kind == .local ? "local" : "openai_compatible")
      if connection.kind == .local { return .local(OllamaProvider(openAICompatible: configured)) }
      return .compatible(OpenAICompatibleProvider(configuration: configured))
    case .hosted:
      guard let endpoint = connection.endpoint, let url = URL(string: endpoint),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
        url.user == nil, url.password == nil else { throw AIConfiguredRuntimeError.invalidEndpoint }
      guard let token = secret(connection), !token.isEmpty else { throw AIConfiguredRuntimeError.missingSecret }
      return .hosted(DayflowBackendProvider(token: token, endpoint: endpoint))
    }
  }

  func generateText(prompt: String, feature: AIFeature = .text) async throws -> (text: String, log: LLMCall) {
    try await withConfiguration(feature: feature) { try await $0.generateText(prompt: prompt, feature: feature) }
  }
}

extension AIFeature {
  var modelFeature: ModelFeature {
    switch self {
    case .timeline: return .timeline
    case .transcription: return .transcription
    case .activityCards: return .activityCards
    case .chat: return .chat
    case .text, .targetEvaluation: return .text
    case .dailyRecap: return .dailyRecap
    case .flow: return .flow
    }
  }
}
