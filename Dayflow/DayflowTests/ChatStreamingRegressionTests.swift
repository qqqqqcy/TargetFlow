import XCTest

@testable import Dayflow

final class ChatStreamingRegressionTests: XCTestCase {
  @MainActor
  func testSessionRecoveryOnlyRetriesMissingSessions() {
    XCTAssertTrue(ChatService.isMissingSessionError("no rollout found for thread id abc"))
    XCTAssertTrue(ChatService.isMissingSessionError("No conversation found with session ID: abc"))
    XCTAssertFalse(ChatService.isMissingSessionError("Rate limit exceeded"))
    XCTAssertFalse(ChatService.isMissingSessionError("Authentication failed"))
  }

  @MainActor
  func testConfiguredTextChatCarriesHistoryAndRealContextWithoutToolClaims() {
    let prompt = ChatService.configuredTextPrompt(
      history: [.user("What did I build?"), .assistant("A timer."), .user("How long?")],
      memory: "Style: brief", context: "2026-10-27: Built timer, 45 minutes")
    XCTAssertTrue(prompt.contains("User: What did I build?"))
    XCTAssertTrue(prompt.contains("Assistant: A timer."))
    XCTAssertTrue(prompt.contains("User: How long?"))
    XCTAssertTrue(prompt.contains("Built timer, 45 minutes"))
    XCTAssertTrue(prompt.contains("no tools or direct database access"))
  }

  func testTextAndTargetEvaluationDispatchIndependentSavedFeatures() async throws {
    let connection = AIProviderConnection(
      name: "HTTP connection", kind: .openAICompatible, endpoint: "https://example.com/v1",
      models: [.init(id: "text-model"), .init(id: "judge-model")])
    let configuration = AIConfiguration(connections: [connection], routes: [
      .text: .init(primary: .init(connectionID: connection.id, modelID: "text-model")),
      .targetEvaluation: .init(primary: .init(
        connectionID: connection.id, modelID: "judge-model", effort: "high")),
    ])
    let service = LLMService(loadConfiguration: { configuration }, configuredText: { prompt, feature in
      "\(feature.rawValue):\(prompt)"
    })
    let text = try await service.generateText(prompt: "summary")
    let evaluation = try await service.generateTargetEvaluation(prompt: "judge")
    XCTAssertEqual(text, "text:summary")
    XCTAssertEqual(evaluation, "targetEvaluation:judge")
  }

  func testDefaultOnlyConfigurationAllowsTextTargetAndStreamingDispatch() async throws {
    let connection = AIProviderConnection(name: "Default", kind: .codexCLI)
    let configuration = AIConfiguration(connections: [connection], defaultModel: .init(connectionID: connection.id, modelID: "model"))
    let service = LLMService(loadConfiguration: { configuration }, configuredText: { prompt, feature in
      "\(feature.rawValue):\(prompt)"
    })
    let text = try await service.generateText(prompt: "summary")
    let evaluation = try await service.generateTargetEvaluation(prompt: "judge")
    XCTAssertEqual(text, "text:summary")
    XCTAssertEqual(evaluation, "targetEvaluation:judge")
    var streamed = ""
    for try await chunk in service.generateTextStreaming(prompt: "stream") { streamed += chunk }
    XCTAssertEqual(streamed, "text:stream")
  }

  func testMissingSavedTextRouteDoesNotUseLegacyProvider() async {
    let service = LLMService(loadConfiguration: { AIConfiguration() }, configuredText: { _, _ in
      XCTFail("An unassigned feature must not dispatch")
      return "unexpected"
    })
    do {
      _ = try await service.generateTargetEvaluation(prompt: "judge")
      XCTFail("Missing route must fail")
    } catch {
      XCTAssertTrue(error is AIConfiguredRuntimeError)
    }
  }

  func testCodexReportsStructuredFailureInsteadOfStdinNotice() throws {
    let detail =
      "The 'unavailable-model' model is not supported when using Codex with a ChatGPT account."
    let nested = String(
      decoding: try JSONSerialization.data(withJSONObject: [
        "type": "error", "error": ["message": detail],
      ]), as: UTF8.self)
    for event: [String: Any] in [
      ["type": "error", "message": nested],
      ["type": "turn.failed", "error": ["message": nested]],
    ] {
      let data = try JSONSerialization.data(withJSONObject: event)
      guard case .error(let message) = ChatCLIProcessRunner().parseCodexEvent(data) else {
        return XCTFail("The API failure must reach the chat UI")
      }
      XCTAssertEqual(message, detail)
    }
  }

  func testStreamingMetadataIsHiddenAtEveryTokenBoundary() {
    let answer = "Target Flow chat test OK."
    let suffix =
      "\n\n```suggestions\n[\"Follow up?\"]\n```\n\n```memory\nProfile: example\nStyle: brief\n```"
    for length in 1...suffix.count {
      let visible = ChatMetadataParser.visibleStreamingText(answer + suffix.prefix(length))
      XCTAssertEqual(visible.trimmingCharacters(in: .whitespacesAndNewlines), answer)
    }
  }

  func testStreamingKeepsOrdinaryCodeAndCharts() {
    for text in ["Answer\n```swift\nlet value = 1\n```\nDone", "```chart type=bar\n{}\n```\n"] {
      XCTAssertEqual(ChatMetadataParser.visibleStreamingText(text), text)
    }
  }
}
