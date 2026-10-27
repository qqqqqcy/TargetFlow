import Foundation

enum AIProviderDiscoveryError: LocalizedError, Equatable {
  case invalidEndpoint, invalidResponse, httpStatus(Int), missingCodexCache, unsupportedDiscovery

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint: return String(localized: "Enter a valid HTTP or HTTPS connection endpoint.")
    case .invalidResponse: return String(localized: "The provider returned an unreadable model list.")
    case .httpStatus(let status): return String(localized: "Model discovery failed (HTTP \(status)). Check the endpoint and credential.")
    case .missingCodexCache: return String(localized: "No Codex model cache was found. Open Codex once, or enter an exact model ID manually.")
    case .unsupportedDiscovery: return String(localized: "This connection does not provide model discovery. Enter an exact model ID manually.")
    }
  }
}

/// Discovery reports only provider metadata. A listed model still needs a real feature validation.
/// No shell commands are run and CLI authentication/configuration files are never changed.
enum AIProviderDiscovery {
  static func discoverModels(
    for connection: AIProviderConnection, secret: String? = nil,
    session: URLSession = .shared
  ) async throws -> [AIConfiguredModel] {
    switch connection.kind {
    case .codexCLI:
      let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
      return try cachedCodexModels(at: home.appendingPathComponent("models_cache.json"))
    case .claudeCLI:
      // Subscription CLI authentication does not expose an API model-list endpoint.
      throw AIProviderDiscoveryError.unsupportedDiscovery
    case .hosted:
      throw AIProviderDiscoveryError.unsupportedDiscovery
    case .gemini, .openAICompatible, .local:
      break
    }
    let endpoint = connection.endpoint
      ?? (connection.kind == .gemini ? "https://generativelanguage.googleapis.com/v1beta" : "")
    var url = try modelsURL(endpoint: endpoint, kind: connection.kind, localEngine: connection.localEngine)
    var models: [AIConfiguredModel] = []
    var seenTokens = Set<String>()
    repeat {
      var request = URLRequest(url: url)
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      if let secret, !secret.isEmpty {
        if connection.kind == .gemini {
          request.setValue(secret, forHTTPHeaderField: "x-goog-api-key")
        } else {
          request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
      }
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw AIProviderDiscoveryError.invalidResponse
      }
      guard (200..<300).contains(response.statusCode) else {
        // Never surface response bodies: relays may echo request credentials.
        throw AIProviderDiscoveryError.httpStatus(response.statusCode)
      }
      let parsed = try parseModels(data, kind: connection.kind, localEngine: connection.localEngine)
      models.append(contentsOf: parsed.models)
      guard connection.kind == .gemini, let token = parsed.nextPageToken, !token.isEmpty else { break }
      guard seenTokens.insert(token).inserted, seenTokens.count <= 100 else {
        throw AIProviderDiscoveryError.invalidResponse
      }
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.queryItems = (components.queryItems ?? []).filter { $0.name != "pageToken" }
        + [URLQueryItem(name: "pageToken", value: token)]
      guard let nextURL = components.url else { throw AIProviderDiscoveryError.invalidEndpoint }
      url = nextURL
    } while true
    return unique(models)
  }

  static func modelsURL(endpoint: String, kind: AIProviderKind, localEngine: String? = nil) throws -> URL {
    guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme), components.host != nil,
      components.user == nil, components.password == nil
    else { throw AIProviderDiscoveryError.invalidEndpoint }
    var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    for suffix in ["chat/completions", "responses", "generateContent", "models", "api/tags"] {
      if path == suffix { path = ""; break }
      if path.hasSuffix("/" + suffix) { path = String(path.dropLast(suffix.count + 1)); break }
    }
    if kind == .local && (localEngine ?? "ollama") == "ollama" {
      if path.hasSuffix("/api") { path = String(path.dropLast(4)) }
      if path == "api" { path = "" }
      if path.hasSuffix("/v1") { path = String(path.dropLast(3)) }
      if path == "v1" { path = "" }
      path = [path, "api/tags"].filter { !$0.isEmpty }.joined(separator: "/")
    } else {
      if kind == .gemini && path.isEmpty { path = "v1beta" }
      path = [path, "models"].filter { !$0.isEmpty }.joined(separator: "/")
    }
    components.path = "/" + path
    components.fragment = nil
    // Credentials belong in headers, never URL query parameters.
    components.queryItems = components.queryItems?.filter {
      !["key", "api_key", "apikey", "token", "access_token"].contains($0.name.lowercased())
    }
    guard let url = components.url else { throw AIProviderDiscoveryError.invalidEndpoint }
    return url
  }

  static func cachedCodexModels(at url: URL) throws -> [AIConfiguredModel] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AIProviderDiscoveryError.missingCodexCache
    }
    let data = try Data(contentsOf: url)
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let values = root["models"] as? [[String: Any]]
    else { throw AIProviderDiscoveryError.invalidResponse }
    return unique(values.compactMap { item in
      guard let id = item["slug"] as? String, !id.isEmpty else { return nil }
      if let visibility = item["visibility"] as? String, visibility == "hide" { return nil }
      let levels = item["supported_reasoning_levels"] as? [[String: Any]]
      let choices = levels?.compactMap { $0["effort"] as? String }
      let modalities = item["input_modalities"] as? [String]
      return AIConfiguredModel(id: id, name: item["display_name"] as? String,
        reasoningChoices: choices, supportsReasoning: choices.map { !$0.isEmpty },
        supportsVision: modalities.map { $0.contains("image") })
    })
  }

  static func parseModels(_ data: Data, kind: AIProviderKind, localEngine: String? = nil) throws
    -> (models: [AIConfiguredModel], nextPageToken: String?)
  {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AIProviderDiscoveryError.invalidResponse
    }
    let key = kind == .openAICompatible || (kind == .local && (localEngine ?? "ollama") != "ollama") ? "data" : "models"
    guard let entries = root[key] as? [[String: Any]] else {
      throw AIProviderDiscoveryError.invalidResponse
    }
    let models: [AIConfiguredModel] = entries.compactMap { item in
      if kind == .gemini {
        if let methods = item["supportedGenerationMethods"] as? [String], !methods.contains("generateContent") {
          return nil
        }
        guard let raw = item["name"] as? String else { return nil }
        let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
        let effort = item["effort"] as? [String: Any]
        let reasoning = item["reasoning"] as? [String: Any]
        let choices = (effort?["supported_levels"] ?? reasoning?["supported_efforts"]) as? [String]
        let modalities = item["input_modalities"] as? [String]
        return AIConfiguredModel(id: id, name: item["displayName"] as? String,
          reasoningChoices: choices,
          supportsReasoning: choices.map { !$0.isEmpty } ?? item["thinking"] as? Bool,
          supportsVision: modalities.map { $0.contains("image") })
      }
      guard let id = (item["id"] ?? item["model"] ?? item["name"]) as? String, !id.isEmpty else { return nil }
      let capabilities = item["capabilities"] as? [String]
      let architecture = item["architecture"] as? [String: Any]
      let modalities = (architecture?["input_modalities"] ?? item["input_modalities"]) as? [String]
      let vision = modalities.map { $0.contains("image") }
        ?? capabilities.map { $0.contains("vision") }
      let parameters = item["supported_parameters"] as? [String]
      // DeepSeek and OpenRouter expose different optional effort metadata.
      // Missing metadata remains unknown rather than implying a fixed allowlist.
      let effort = item["effort"] as? [String: Any]
      let reasoningMetadata = item["reasoning"] as? [String: Any]
      let choices = (effort?["supported_levels"] ?? reasoningMetadata?["supported_efforts"]) as? [String]
      let reasoning = choices.map { !$0.isEmpty }
        ?? parameters.map { $0.contains("reasoning") || $0.contains("reasoning_effort") }
        ?? capabilities.map { $0.contains("thinking") }
      return AIConfiguredModel(id: id, name: item["name"] as? String,
        reasoningChoices: choices, supportsReasoning: reasoning, supportsVision: vision)
    }
    return (unique(models), root["nextPageToken"] as? String)
  }

  private static func unique(_ models: [AIConfiguredModel]) -> [AIConfiguredModel] {
    var seen = Set<String>()
    return models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
  }
}
