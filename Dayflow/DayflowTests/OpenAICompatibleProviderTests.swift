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

  @MainActor
  func testTimelineAcceptsPromptedFramesAndCardsEnvelopeWithoutRetry() async throws {
    let fixture = try AIValidationFixture()
    defer { fixture.remove() }
    let policy = TimelineOutputPolicy()
    let start = fixture.screenshots.first!.capturedAt / 60 * 60
    let end = fixture.screenshots.last!.capturedAt / 60 * 60 + 60
    // Schema retained from MacBook Pro validation calls 820–822. The model
    // followed the one-step prompt; the HTTP adapter previously expected [].
    let envelope: [String: Any] = [
      "frames": [["time": policy.formatTimestampForPrompt(start), "app": "Unknown",
        "note": AIValidationFixture.imageMarker]],
      "cards": [["startTime": policy.formatTimestampForPrompt(start),
        "endTime": policy.formatTimestampForPrompt(end), "category": "Work",
        "subcategory": "", "title": "Validation report",
        "summary": AIValidationFixture.imageMarker, "detailedSummary": "Synthetic evidence",
        "distractions": [], "appSites": ["primary": ""]]],
    ]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    for output in [json, "```json\n" + json + "\n```"] {
      var calls = 0
      let provider = OpenAICompatibleProvider(configuration: configuration()) { request, operation, _ in
        calls += 1
        XCTAssertEqual(operation, "generate_timeline")
        XCTAssertTrue(request.messages[1].content[0].text!.contains("\"frames\""))
        return output
      }
      let result = try await provider.generateTimeline(
        screenshots: fixture.screenshots, context: fixture.context, batchId: nil)
      XCTAssertEqual(calls, 1, "Valid envelopes must not be retried as malformed output")
      try AIValidationFixture.checkCards(result.cards, expected: AIValidationFixture.imageMarker)
      XCTAssertEqual(result.cards.first?.startTime, policy.formatTimestampForPrompt(start))
      XCTAssertEqual(result.cards.first?.endTime, policy.formatTimestampForPrompt(end))
      XCTAssertEqual(result.log.output, output)
      XCTAssertFalse(result.observations.isEmpty)
    }
  }

  func testRedactedStoredFramesReachTimelineAsBlackImages() async throws {
    let image = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 18, bitsPerSample: 8,
      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    image.bitmapData!.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
    try XCTUnwrap(image.representation(using: .jpeg, properties: [:])).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) + 9 * 3600
    let shots = [0, 60].map { offset in
      Screenshot(id: Int64(offset), capturedAt: start + offset, filePath: url.path,
        fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false, isPrivacyRedacted: true)
    }
    let context = ActivityGenerationContext(batchObservations: [], existingCards: [],
      currentTime: Date(), categories: [], hasPreviousCardWithinFiveMinutes: false)
    var calls = 0
    let provider = OpenAICompatibleProvider(configuration: configuration()) { request, operation, _ in
      calls += 1
      XCTAssertEqual(operation, "generate_timeline")
      let content = request.messages[1].content
      XCTAssertTrue(content[0].text!.contains(TimelinePrivacyPromptGuidance.instructions))
      let images = content.compactMap(\.image_url)
      XCTAssertEqual(images.count, 2)
      for image in images {
        let base64 = try XCTUnwrap(image.url.split(separator: ",").last)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Data(base64Encoded: String(base64)))))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 16, y: 9)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(pixel.redComponent, 0.02)
        XCTAssertLessThan(pixel.greenComponent, 0.02)
        XCTAssertLessThan(pixel.blueComponent, 0.02)
      }
      return """
        [{"startTime":"9:00 AM","endTime":"9:02 AM","category":"Idle","subcategory":"","title":"Content unavailable","summary":"Content hidden by privacy settings during this interval.","detailedSummary":"9:00 AM - 9:02 AM: Content unavailable due to privacy redaction.","distractions":[],"appSites":{}}]
        """
    }
    let result = try await provider.generateTimeline(screenshots: shots, context: context, batchId: nil)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(result.cards.count, 1)
    XCTAssertEqual(result.cards.first?.title, "Content unavailable")
    XCTAssertEqual(result.cards.first?.summary, "Content hidden by privacy settings during this interval.")
    XCTAssertNotEqual(result.cards.first?.evidenceKind, .privacyRedacted)
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
    image.bitmapData!.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).jpg")
    try XCTUnwrap(image.representation(using: .jpeg, properties: [:])).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let screenshots = (0..<31).map { index in
      Screenshot(
        id: Int64(index), capturedAt: 1000 + index * 30, filePath: url.path,
        fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false, isPrivacyRedacted: true)
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
      XCTAssertTrue(content[0].text!.contains(TimelinePrivacyPromptGuidance.instructions))
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
      distractions: nil, appSites: nil, evidenceKind: .privacyRedacted)
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
      XCTAssertTrue(prompt.contains(TimelinePrivacyPromptGuidance.instructions))
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


}
