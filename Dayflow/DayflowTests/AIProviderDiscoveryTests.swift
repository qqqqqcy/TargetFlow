import Foundation
import XCTest
@testable import Dayflow

private final class DiscoveryURLProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler!(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status,
        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

final class AIProviderDiscoveryTests: XCTestCase {
  func testOpenAIModelsPreserveUnknownCapabilitiesAndDeduplicateIDs() throws {
    let data = Data(#"{"data":[{"id":"relay/custom"},{"id":"relay/custom"},{"id":"vision","architecture":{"input_modalities":["text","image"]},"supported_parameters":["reasoning"]}]}"#.utf8)
    let models = try AIProviderDiscovery.parseModels(data, kind: .openAICompatible).models
    XCTAssertEqual(models.map(\.id), ["relay/custom", "vision"])
    XCTAssertNil(models[0].supportsReasoning)
    XCTAssertNil(models[0].supportsVision)
    XCTAssertNil(models[0].reasoningChoices)
    XCTAssertEqual(models[1].supportsVision, true)
    XCTAssertEqual(models[1].supportsReasoning, true)
    XCTAssertNil(models[1].reasoningChoices)
  }

  func testOfficialEffortMetadataUsesProviderAllowlist() throws {
    let data = Data(#"{"data":[{"id":"deepseek","input_modalities":["text"],"effort":{"supported_levels":["low","high","max"]}},{"id":"router","reasoning":{"supported_efforts":["minimal","high"]}},{"id":"unknown","reasoning":{"supported_efforts":null}}]}"#.utf8)
    let models = try AIProviderDiscovery.parseModels(data, kind: .openAICompatible).models
    XCTAssertEqual(models[0].reasoningChoices, ["low", "high", "max"])
    XCTAssertEqual(models[0].supportsVision, false)
    XCTAssertEqual(models[1].reasoningChoices, ["minimal", "high"])
    XCTAssertNil(models[2].reasoningChoices)
  }

  func testFutureEffortsAndModelDisplayNamesComeFromResponse() throws {
    let data = Data(#"{"models":[{"name":"models/future-id","displayName":"Provider display name","effort":{"supported_levels":["future-level"]},"input_modalities":["text","image"]}]}"#.utf8)
    let model = try XCTUnwrap(AIProviderDiscovery.parseModels(data, kind: .gemini).models.first)
    XCTAssertEqual(model.name, "Provider display name")
    XCTAssertEqual(model.reasoningChoices, ["future-level"])
    XCTAssertEqual(model.supportsVision, true)
  }

  func testClaudeSubscriptionDoesNotInventDiscoveredModels() async {
    do {
      _ = try await AIProviderDiscovery.discoverModels(for: .init(name: "Claude", kind: .claudeCLI))
      XCTFail("Subscription model discovery must be explicit about being unavailable")
    } catch {
      XCTAssertEqual(error as? AIProviderDiscoveryError, .unsupportedDiscovery)
    }
  }

  func testGeminiModelsFilterNonGenerationModelsAndExposePagination() throws {
    let data = Data(#"{"models":[{"name":"models/gemini-exact","displayName":"Exact Gemini","thinking":true,"supportedGenerationMethods":["generateContent"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"page-2"}"#.utf8)
    let result = try AIProviderDiscovery.parseModels(data, kind: .gemini)
    XCTAssertEqual(result.models.map(\.id), ["gemini-exact"])
    XCTAssertEqual(result.models.first?.name, "Exact Gemini")
    XCTAssertEqual(result.models.first?.supportsReasoning, true)
    XCTAssertNil(result.models.first?.supportsVision)
    XCTAssertEqual(result.nextPageToken, "page-2")
  }

  func testOllamaCapabilitiesStayUnknownUnlessReported() throws {
    let data = Data(#"{"models":[{"name":"local:latest","details":{"family":"llama"}},{"model":"vision:latest","capabilities":["completion","vision"]}]}"#.utf8)
    let models = try AIProviderDiscovery.parseModels(data, kind: .local).models
    XCTAssertEqual(models.map(\.id), ["local:latest", "vision:latest"])
    XCTAssertNil(models[0].supportsVision)
    XCTAssertEqual(models[1].supportsVision, true)
    XCTAssertEqual(models[1].supportsReasoning, false)
  }

  func testDiscoveryURLPreservesRelayPathAndUsesLocalEngine() throws {
    XCTAssertEqual(try AIProviderDiscovery.modelsURL(endpoint: "https://relay.example/api/v1/chat/completions", kind: .openAICompatible).absoluteString,
      "https://relay.example/api/v1/models")
    XCTAssertEqual(try AIProviderDiscovery.modelsURL(endpoint: "http://localhost:11434/v1", kind: .local).absoluteString,
      "http://localhost:11434/api/tags")
    XCTAssertEqual(try AIProviderDiscovery.modelsURL(endpoint: "http://localhost:1234/v1", kind: .local, localEngine: "lmstudio").absoluteString,
      "http://localhost:1234/v1/models")
    XCTAssertEqual(try AIProviderDiscovery.modelsURL(endpoint: "https://generativelanguage.googleapis.com", kind: .gemini).absoluteString,
      "https://generativelanguage.googleapis.com/v1beta/models")
    let url = try AIProviderDiscovery.modelsURL(endpoint: "https://relay.example/v1?key=secret&region=eu", kind: .openAICompatible)
    XCTAssertFalse(url.absoluteString.contains("secret"))
    XCTAssertTrue(url.absoluteString.contains("region=eu"))
    XCTAssertThrowsError(try AIProviderDiscovery.modelsURL(endpoint: "https://user:secret@example.com/v1", kind: .openAICompatible))
  }

  func testCodexCacheReadsExactModelsEffortsAndVisionWithoutChangingFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("models_cache.json")
    let data = Data(#"{"models":[{"slug":"exact-codex-id","display_name":"Custom Codex","supported_reasoning_levels":[{"effort":"high"},{"effort":"ultra"}],"input_modalities":["text","image"]},{"slug":"text-only","input_modalities":["text"]},{"slug":"hidden","visibility":"hide"}]}"#.utf8)
    try data.write(to: file)
    let models = try AIProviderDiscovery.cachedCodexModels(at: file)
    XCTAssertEqual(models.map(\.id), ["exact-codex-id", "text-only"])
    XCTAssertEqual(models[0].reasoningChoices, ["high", "ultra"])
    XCTAssertEqual(models[0].supportsReasoning, true)
    XCTAssertEqual(models[0].supportsVision, true)
    XCTAssertEqual(models[1].supportsVision, false)
    XCTAssertNil(models[1].supportsReasoning)
    XCTAssertEqual(try Data(contentsOf: file), data)
  }

  func testHTTPDiscoveryUsesCredentialHeadersAndFollowsGeminiPages() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DiscoveryURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel(); DiscoveryURLProtocol.handler = nil }
    var requests: [URLRequest] = []
    DiscoveryURLProtocol.handler = { request in
      requests.append(request)
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-secret")
      XCTAssertFalse(request.url!.absoluteString.contains("test-secret"))
      let body = requests.count == 1
        ? #"{"models":[{"name":"models/first"}],"nextPageToken":"next"}"#
        : #"{"models":[{"name":"models/second"}]}"#
      return (200, Data(body.utf8))
    }
    let connection = AIProviderConnection(name: "Test Gemini", kind: .gemini,
      endpoint: "https://discovery.example/v1beta")
    let models = try await AIProviderDiscovery.discoverModels(for: connection,
      secret: "test-secret", session: session)
    XCTAssertEqual(models.map(\.id), ["first", "second"])
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[1].url!.absoluteString.contains("pageToken=next"))
  }

  func testHTTPFailureDoesNotExposeProviderResponseBody() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DiscoveryURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel(); DiscoveryURLProtocol.handler = nil }
    DiscoveryURLProtocol.handler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sensitive")
      return (401, Data("credential: sensitive".utf8))
    }
    let connection = AIProviderConnection(name: "Relay", kind: .openAICompatible,
      endpoint: "https://discovery.example/v1")
    do {
      _ = try await AIProviderDiscovery.discoverModels(for: connection, secret: "sensitive", session: session)
      XCTFail("Expected HTTP failure")
    } catch {
      XCTAssertEqual(error as? AIProviderDiscoveryError, .httpStatus(401))
      XCTAssertFalse(error.localizedDescription.contains("sensitive"))
    }
  }

  func testMalformedDiscoveryResponsesAreRejected() {
    for raw in ["invalid", "[]", "{\"error\":\"unauthorized\"}"] {
      XCTAssertThrowsError(try AIProviderDiscovery.parseModels(Data(raw.utf8), kind: .openAICompatible))
    }
  }
}
