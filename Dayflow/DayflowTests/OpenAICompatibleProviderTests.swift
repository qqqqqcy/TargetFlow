import AppKit
import XCTest

@testable import Dayflow

final class OpenAICompatibleProviderTests: XCTestCase {
  private func configuration(_ endpoint: String = "https://openrouter.ai/api/v1")
    -> OpenAICompatibleRuntimeConfiguration
  {
    .init(
      configuration: .init(preset: .custom, baseURL: endpoint, modelID: "chosen-model"),
      bearerToken: "test-token")
  }

  @MainActor
  func testDirectTimelineSendsImagesAndReturnsCardsInOneCall() async throws {
    let fixture = try AIValidationFixture()
    defer { fixture.remove() }
    var calls = 0
    let provider = OpenAICompatibleProvider(configuration: configuration()) { request, operation, _ in
      calls += 1
      XCTAssertEqual(operation, "generate_timeline")
      let data = try JSONEncoder().encode(request)
      let body = String(decoding: data, as: UTF8.self)
      XCTAssertTrue(body.contains("image_url"))
      return """
        [{"startTime":"10:13 PM","endTime":"10:29 PM","category":"Work","subcategory":"Writing","title":"Editing report","summary":"DAYFLOW VISION 4729","detailedSummary":"10:13 PM - 10:29 PM: Edited report.","distractions":[],"appSites":{"primary":"Editor","secondary":""}}]
        """
    }
    // Fix the context to a local, deterministic clock time for coverage validation.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 22, minute: 13))!
    let shots = [0, 900].map { offset in
      Screenshot(id: Int64(offset), capturedAt: Int(start.timeIntervalSince1970) + offset,
        filePath: fixture.imageURL.path, fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false)
    }
    let result = try await provider.generateTimeline(screenshots: shots, context: fixture.context, batchId: nil)
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(result.cards.isEmpty)
    XCTAssertFalse(result.observations.isEmpty)
  }

  func testReasoningOnlySentToOpenRouter() throws {
    for endpoint in ["https://openrouter.ai/api/v1", "https://example.com/v1"] {
      let provider = OpenAICompatibleProvider(configuration: configuration(endpoint))
      let request = provider.makeRequest(content: [])
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, "chosen-model")
      if endpoint.contains("openrouter.ai") {
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
      } else {
        XCTAssertNil(body["reasoning"])
      }
    }
  }

  func testHTTPSelectionUsesFeatureModelAndProtocolReasoningField() throws {
    let suite = "HTTPModelPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ModelPreferences(
      defaultSelection: .init(model: "global-model", reasoningEffort: .high),
      featureOverrides: [.transcription: .init(model: "vision-model", reasoningEffort: ModelReasoningEffort.none)])
    try preferences.save(provider: .openAICompatible, to: defaults)

    for endpoint in ["https://openrouter.ai/api/v1", "https://api.openai.com/v1"] {
      let transport = OllamaProvider(openAICompatible: configuration(endpoint))
      let request = transport.configuredRequest(
        .init(model: "legacy-model", messages: []), feature: .transcription, defaults: defaults)
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, "vision-model")
      if endpoint.contains("openrouter.ai") {
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        XCTAssertNil(body["reasoning_effort"])
      } else {
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertNil(body["reasoning"])
      }
    }
  }

  func testExplicitProviderDefaultOmitsLegacyReasoning() throws {
    let suite = "HTTPModelPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try ModelPreferences(defaultSelection: .init(reasoningEffort: .providerDefault))
      .save(provider: .openAICompatible, to: defaults)
    let transport = OllamaProvider(openAICompatible: configuration())
    let request = transport.configuredRequest(
      .init(model: "legacy", messages: [], reasoning: .init(effort: "low")),
      feature: .activityCards, defaults: defaults)
    XCTAssertNil(request.reasoning)
    XCTAssertNil(request.reasoning_effort)
  }

  func testScreenshotsTravelTogetherWithActualTimestamps() async throws {
    let image = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).jpg")
    try XCTUnwrap(image.representation(using: .jpeg, properties: [:])).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let screenshots = (0..<31).map { index in
      Screenshot(
        id: Int64(index), capturedAt: 1000 + index * 30, filePath: url.path,
        fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false)
    }
    var requests = 0
    let provider = OpenAICompatibleProvider(configuration: configuration()) {
      request, operation, _ in
      requests += 1
      XCTAssertEqual(operation, "transcribe_screenshots")
      let content = request.messages[1].content
      XCTAssertEqual(content.filter { $0.type == "image_url" }.count, 15)
      XCTAssertTrue(content.contains { $0.text == "Screenshot at 00:15:00:" })
      XCTAssertFalse(content[0].text!.contains("1 min apart"))
      return
        #"{"segments":[{"start":"00:00:00","end":"00:15:00","description":"Edited the release notes."}]}"#
    }
    let result = try await provider.transcribeScreenshots(
      screenshots, batchStartTime: Date(timeIntervalSince1970: 1000), batchId: 1)
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(result.observations.first?.startTs, 1000)
    XCTAssertEqual(result.observations.first?.endTs, 1900)
    XCTAssertEqual(result.observations.first?.llmModel, "chosen-model")
  }

  func testCardRetryRetainsFullContextAndReturnsDetailedCards() async throws {
    let previous = ActivityCardData(
      startTime: "1:00 PM", endTime: "1:15 PM", category: "Work", subcategory: "",
      title: "Release notes", summary: "Edited release notes.", detailedSummary: "Details",
      distractions: nil, appSites: nil)
    let context = ActivityGenerationContext(
      batchObservations: [], existingCards: [previous], currentTime: Date(), categories: [],
      hasPreviousCardWithinFiveMinutes: true)
    var requests = 0
    let provider = OpenAICompatibleProvider(configuration: configuration()) { request, _, _ in
      requests += 1
      let prompt = request.messages[1].content[0].text!
      XCTAssertTrue(prompt.contains("<previous_cards>"))
      XCTAssertTrue(prompt.contains("</previous_cards>"))
      XCTAssertTrue(prompt.contains("Release notes"))
      if requests == 1 { return "[]" }
      XCTAssertTrue(prompt.contains("PREVIOUS ATTEMPT FAILED"))
      return "```json\n" + String(data: try JSONEncoder().encode([previous]), encoding: .utf8)!
        + "\n```"
    }
    let result = try await provider.generateActivityCards(
      observations: [], context: context, batchId: 1)
    XCTAssertEqual(requests, 2)
    XCTAssertEqual(result.cards.first?.detailedSummary, "Details")
  }
  func testConfiguredDeepSeekRequestCarriesSharedCardPrompts() async throws {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: ActivityCardPromptPreferences.storageKey)
    defer {
      if let previous { defaults.set(previous, forKey: ActivityCardPromptPreferences.storageKey) }
      else { defaults.removeObject(forKey: ActivityCardPromptPreferences.storageKey) }
    }
    try ActivityCardPromptPreferences.saveVerified(.init(
      titleBlock: "CUSTOM_DEEPSEEK_TITLE", summaryBlock: "CUSTOM_DEEPSEEK_SUMMARY",
      detailedBlock: "CUSTOM_DEEPSEEK_DETAILS"))
    let connection = AIProviderConnection(
      name: "DeepSeek", kind: .openAICompatible, endpoint: "https://api.deepseek.com/v1")
    let configuration = AIConfiguration(connections: [connection], defaultModel: .init(
      connectionID: connection.id, modelID: "deepseek-chat"))
    let selection = try configuration.selection(for: XCTUnwrap(configuration.defaultModel))
    let runtime = OpenAICompatibleRuntimeConfiguration(
      configuration: .init(preset: .custom, baseURL: connection.endpoint!, modelID: selection.modelID),
      bearerToken: "test-token")
    let card = ActivityCardData(
      startTime: "1:00 PM", endTime: "1:15 PM", category: "Work", subcategory: "",
      title: "Release notes", summary: "Edited release notes.", detailedSummary: "Details",
      distractions: nil, appSites: nil)
    var requests = 0
    let provider = OpenAICompatibleProvider(configuration: runtime) { request, operation, _ in
      requests += 1
      XCTAssertEqual(operation, "generate_cards")
      XCTAssertEqual(request.model, "deepseek-chat")
      let prompt = try XCTUnwrap(request.messages[1].content.first?.text)
      for marker in ["CUSTOM_DEEPSEEK_TITLE", "CUSTOM_DEEPSEEK_SUMMARY", "CUSTOM_DEEPSEEK_DETAILS"] {
        XCTAssertTrue(prompt.contains(marker))
      }
      return String(decoding: try JSONEncoder().encode([card]), as: UTF8.self)
    }
    let context = ActivityGenerationContext(
      batchObservations: [], existingCards: [card], currentTime: Date(), categories: [],
      hasPreviousCardWithinFiveMinutes: true)
    let result = try await AIRequestContext.$assignment.withValue(selection) {
      try await provider.generateActivityCards(observations: [], context: context, batchId: nil)
    }
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(result.cards.first?.title, card.title)
  }

}
