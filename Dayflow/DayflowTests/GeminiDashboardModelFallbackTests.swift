import XCTest

@testable import Dayflow

final class GeminiDashboardModelFallbackTests: XCTestCase {
  func testFallsBackInRequestedOrderAndStopsOnSuccess() async throws {
    var attempted: [GeminiModel] = []
    let result = try await GeminiDirectProvider.withDashboardModelFallback { model in
      attempted.append(model)
      if model != .flash35 { throw NSError(domain: "Test", code: 503) }
      return .init(text: "OK", functionCalls: [], modelFunctionCallParts: [])
    }
    XCTAssertEqual(attempted, [.flash38, .flash37, .flash36, .flash35])
    XCTAssertEqual(result.text, "OK")
  }

  func testExhaustionReachesFlashLiteAndPreservesLastError() async {
    var attempted: [GeminiModel] = []
    do {
      _ = try await GeminiDirectProvider.withDashboardModelFallback { model in
        attempted.append(model)
        throw NSError(domain: model.rawValue, code: 503)
      }
      XCTFail("Expected final failure")
    } catch {
      XCTAssertEqual((error as NSError).domain, "gemini-3.5-flash-lite")
    }
    XCTAssertEqual(attempted, [.flash38, .flash37, .flash36, .flash35, .flashLite35])
  }

  func testCustomSelectionAndExplicitFallbackPolicy() throws {
    let suite = "GeminiModelPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = GeminiDirectProvider(apiKey: "test")
    try ModelPreferences(
      defaultSelection: .init(model: "gemini-custom"), fallbackModels: [])
      .save(provider: .gemini, to: defaults)
    XCTAssertEqual(provider.selectedModels(feature: .chat, defaults: defaults), ["gemini-custom"])
    try ModelPreferences(
      defaultSelection: .init(model: "gemini-custom"),
      featureOverrides: [.chat: .init(model: "gemini-chat")],
      fallbackModels: ["gemini-fallback", "gemini-chat"])
      .save(provider: .gemini, to: defaults)
    XCTAssertEqual(provider.selectedModels(feature: .chat, defaults: defaults),
      ["gemini-chat", "gemini-fallback"])
  }

  func testProviderDefaultThinkingOmitsLegacyHigh() throws {
    let suite = "GeminiModelPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = GeminiDirectProvider(apiKey: "test")
    XCTAssertEqual(try provider.thinkingConfig(
      feature: .text, model: "gemini-3.8-flash", defaults: defaults)?["thinkingLevel"] as? String, "high")
    try ModelPreferences(defaultSelection: .init(reasoningEffort: .providerDefault))
      .save(provider: .gemini, to: defaults)
    XCTAssertNil(try provider.thinkingConfig(
      feature: .text, model: "gemini-3.8-flash", defaults: defaults))
  }

  func testCustomChatFallbackUsesSuppliedIDs() async throws {
    var attempted: [String] = []
    let result = try await GeminiDirectProvider.withDashboardModelFallback(
      models: ["custom-primary", "custom-backup"]
    ) { model in
      attempted.append(model)
      if model == "custom-primary" { throw NSError(domain: "Test", code: 503) }
      return .init(text: "OK", functionCalls: [], modelFunctionCallParts: [])
    }
    XCTAssertEqual(attempted, ["custom-primary", "custom-backup"])
    XCTAssertEqual(result.text, "OK")
  }

  func testCancellationDoesNotTryAnotherModel() async {
    var attempted: [GeminiModel] = []
    do {
      _ = try await GeminiDirectProvider.withDashboardModelFallback { model in
        attempted.append(model)
        throw CancellationError()
      }
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(attempted, [.flash38])
  }
}
