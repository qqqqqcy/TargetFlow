import XCTest

@testable import Dayflow

final class CodexClaudeProviderTests: XCTestCase {
  private let runner = ChatCLIProcessRunner()
  private let claudeProvider = ClaudeProvider()

  func testSharedPromptsReachBothCLIStageAndOneStepBuilders() throws {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: ActivityCardPromptPreferences.storageKey)
    defer {
      if let previous { defaults.set(previous, forKey: ActivityCardPromptPreferences.storageKey) }
      else { defaults.removeObject(forKey: ActivityCardPromptPreferences.storageKey) }
    }
    try ActivityCardPromptPreferences.saveVerified(.init(
      titleBlock: "CLI_SHARED_TITLE", summaryBlock: "CLI_SHARED_SUMMARY", detailedBlock: "CLI_SHARED_DETAILS"))
    let context = ActivityGenerationContext(
      batchObservations: [], existingCards: [], currentTime: Date(), categories: [],
      hasPreviousCardWithinFiveMinutes: false)
    let frames = OneStepTimelineFrames(directory: URL(fileURLWithPath: "/tmp"), frames: [
      .init(capturedAt: 3600, url: URL(fileURLWithPath: "/tmp/shared-prompt-frame.jpg"))])
    let prompts = [
      CodexProvider().buildCardsPrompt(observations: [], context: context),
      claudeProvider.buildCardsPrompt(observations: [], context: context),
      CodexProvider().buildTimelinePrompt(frames: frames, previousCards: [], categories: []),
      claudeProvider.buildTimelinePrompt(frames: frames, previousCards: [], categories: []),
    ]
    for prompt in prompts {
      for marker in ["CLI_SHARED_TITLE", "CLI_SHARED_SUMMARY", "CLI_SHARED_DETAILS"] {
        XCTAssertTrue(prompt.contains(marker))
      }
      XCTAssertTrue(prompt.contains("detailedSummary"))
    }
  }

  func testClaudeStreamingCommandIncludesExplicitEffort() {
    let parts = runner.buildClaudeStreamingCommandParts(
      prompt: "Generate cards",
      model: "sonnet",
      reasoningEffort: "medium",
      sessionId: nil
    )

    XCTAssertEqual(
      Array(parts.prefix(10)),
      [
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--model", LoginShellRunner.shellEscape("sonnet"),
        "--effort", LoginShellRunner.shellEscape("medium"),
      ]
    )
  }

  func testClaudeStreamingResumeKeepsExplicitEffort() {
    let parts = runner.buildClaudeStreamingCommandParts(
      prompt: "Fix the cards",
      model: "sonnet",
      reasoningEffort: "medium",
      sessionId: "session-123"
    )

    XCTAssertEqual(
      Array(parts.prefix(12)),
      [
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--resume", "session-123", "--model",
        LoginShellRunner.shellEscape("sonnet"), "--effort", LoginShellRunner.shellEscape("medium"),
      ]
    )
  }

  func testClaudeActivityCardsUseSonnetSlugAtLowEffort() {
    let configuration = ClaudeProvider.activityCardModelConfiguration()

    XCTAssertEqual(configuration.model, "sonnet")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testChatGPTActivityCardsUseGPT61SolAtLowEffort() {
    let configuration = CodexProvider.activityCardModelConfiguration()

    XCTAssertEqual(configuration.model, "gpt-6.1-sol")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testChatGPTTranscriptionUsesGPT6LunaAtLowEffort() {
    let configuration = CodexProvider.transcriptionModelConfiguration()

    XCTAssertEqual(configuration.model, "gpt-6-luna")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testAvailabilityFallbackIsBoundedAndOnlyHandlesModelAccess() {
    let unavailable = NSError(
      domain: "ChatCLI", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "The model gpt-6-luna is not supported when using Codex with a ChatGPT account"
      ])
    XCTAssertEqual(
      CodexProvider.availabilityFallback(for: "gpt-6-luna", error: unavailable), "gpt-5.6-luna")
    XCTAssertEqual(
      CodexProvider.availabilityFallback(for: "gpt-6.1-sol", error: unavailable), "gpt-5.6-sol")
    XCTAssertNil(CodexProvider.availabilityFallback(for: "gpt-5.6-luna", error: unavailable))
    for message in [
      "invalid_api_key", "hit your usage limit", "model service unavailable (503)",
      "model response is empty", "model: gpt-6-luna\nCountry, region, or territory not supported",
    ] {
      let error = NSError(
        domain: "ChatCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
      XCTAssertNil(CodexProvider.availabilityFallback(for: "gpt-6-luna", error: error))
    }
  }

  func testClaudeTranscriptionUsesSonnetSlugAtLowEffort() {
    let configuration = ClaudeProvider.transcriptionModelConfiguration()

    XCTAssertEqual(configuration.model, "sonnet")
    XCTAssertEqual(configuration.reasoningEffort, "low")
  }

  func testLegacyCardCoverageAllowsBridgingExistingGaps() {
    let existingCards = [
      card(start: "9:00 AM", end: "9:15 AM", title: "Before gap"),
      card(start: "9:25 AM", end: "9:40 AM", title: "After gap"),
    ]
    let generatedCards = [
      card(start: "9:00 AM", end: "9:40 AM", title: "Combined session")
    ]

    let result = claudeProvider.validateTimeCoverage(
      existingCards: existingCards,
      newCards: generatedCards
    )

    XCTAssertTrue(result.isValid)
  }

  func testLegacyCardCoverageAllowsThreeMinutesOfBoundaryDrift() {
    let existingCards = [card(start: "9:00 AM", end: "9:30 AM", title: "Existing")]

    XCTAssertTrue(
      claudeProvider.validateTimeCoverage(
        existingCards: existingCards,
        newCards: [card(start: "9:03 AM", end: "9:30 AM", title: "Within tolerance")]
      ).isValid
    )
    XCTAssertFalse(
      claudeProvider.validateTimeCoverage(
        existingCards: existingCards,
        newCards: [card(start: "9:04 AM", end: "9:30 AM", title: "Outside tolerance")]
      ).isValid
    )
  }

  func testLegacyCardDurationOnlyRejectsShortNonFinalCards() {
    XCTAssertTrue(
      claudeProvider.validateTimeline([
        card(start: "9:00 AM", end: "10:30 AM", title: "Long card"),
        card(start: "10:30 AM", end: "10:35 AM", title: "Short final card"),
      ]).isValid
    )
    XCTAssertFalse(
      claudeProvider.validateTimeline([
        card(start: "9:00 AM", end: "9:05 AM", title: "Short non-final card"),
        card(start: "9:05 AM", end: "9:20 AM", title: "Final card"),
      ]).isValid
    )
  }

  func testLegacyCardValidationNormalizesConfiguredCategories() {
    let category = LLMCategoryDescriptor(
      id: UUID(),
      name: "Deep Work",
      colorHex: "000000",
      description: nil,
      isSystem: false,
      isIdle: false
    )
    let cards = [
      card(start: "9:00 AM", end: "9:30 AM", category: "deep work", title: "Writing")
    ]

    let normalized = claudeProvider.normalizeCards(cards, descriptors: [category])

    XCTAssertEqual(normalized.first?.category, "Deep Work")
  }

  func testLegacyTranscriptionValidationSortsSegmentsAndAllowsTwoSecondDrift() {
    let segments = [
      segment(start: "00:00:28", end: "00:00:58", description: "Second"),
      segment(start: "00:00:02", end: "00:00:30", description: "First"),
    ]

    XCTAssertNil(claudeProvider.validateSegments(segments, duration: 60))
  }

  func testLegacyTranscriptionValidationRejectsDriftBeyondTwoSeconds() {
    let segments = [
      segment(start: "00:00:03", end: "00:00:30", description: "First"),
      segment(start: "00:00:30", end: "00:00:57", description: "Second"),
    ]

    XCTAssertNotNil(claudeProvider.validateSegments(segments, duration: 60))
  }

  func testLegacyTranscriptionValidationDoesNotRejectEmptyDescriptions() {
    let segments = [
      segment(start: "00:00:00", end: "00:01:00", description: "   ")
    ]

    XCTAssertNil(claudeProvider.validateSegments(segments, duration: 60))
  }

  func testLegacyTranscriptionParserExtractsJSONFromWrappedOutput() throws {
    let output = """
      I inspected the screenshots.
      ```json
      {"segments":[{"start":"00:00:00","end":"00:01:00","description":"Writing"}]}
      ```
      """

    let segments = try claudeProvider.parseSegments(from: output, stderr: "")

    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments.first?.description, "Writing")
  }

  func testTelemetryErrorSanitizerKeepsUsefulValidationReasonWithoutCardData() {
    let detail = """
      Missing coverage from 9:00 AM to 9:04 AM.

      📥 INPUT CARDS:
      Secret Project — customer@example.com
      """

    let sanitized = TelemetryErrorSanitizer.sanitize(detail)

    XCTAssertEqual(sanitized, "Missing coverage from 9:00 AM to 9:04 AM.")
  }

  func testTelemetryErrorSanitizerRedactsCommonIdentifiersAndBoundsLength() {
    let detail =
      "user@example.com /Users/jerry/private.txt https://example.com sk-proj-abcdefghijklmnop "
      + String(repeating: "x", count: 600)

    let sanitized = TelemetryErrorSanitizer.sanitize(detail)

    XCTAssertNotNil(sanitized)
    XCTAssertLessThanOrEqual(sanitized?.count ?? 0, 500)
    XCTAssertFalse(sanitized?.contains("user@example.com") ?? true)
    XCTAssertFalse(sanitized?.contains("/Users/jerry") ?? true)
    XCTAssertFalse(sanitized?.contains("https://example.com") ?? true)
    XCTAssertFalse(sanitized?.contains("sk-proj-abcdefghijklmnop") ?? true)
  }

  func testTelemetryErrorSanitizerRedactsCardTitlesContainingApostrophes() {
    let sanitized = TelemetryErrorSanitizer.sanitize(
      "Card 2 'Don\'t expose customer@example.com' is only 5.0 minutes long"
    )

    XCTAssertEqual(sanitized, "Card 2 is only 5.0 minutes long")
  }

  func testTelemetryErrorSanitizerNormalizesModelSuppliedTimestamps() {
    let sanitized = TelemetryErrorSanitizer.sanitize(
      "Segment end time must be after start time: customer@example.com -> secret project"
    )

    XCTAssertEqual(sanitized, "Segment end time must be after start time.")
  }

  func testTelemetryFailureStdoutRemovesJSONAndKeepsCLIText() {
    let stdout = """
      warning: invalid model alias
      {"type":"result","result":"customer@example.com opened Secret Project"}
      retry with a supported model
      """

    let sanitized = TelemetryErrorSanitizer.sanitizeFailureStdout(stdout)

    XCTAssertEqual(sanitized?.originalLength, stdout.count)
    XCTAssertTrue(sanitized?.removedJSON ?? false)
    XCTAssertEqual(
      sanitized?.detail,
      "warning: invalid model alias\n\nretry with a supported model"
    )
    XCTAssertFalse(sanitized?.detail?.contains("Secret Project") ?? true)
  }

  func testTelemetryFailureStdoutRemovesFencedJSONBeforeRedactingText() {
    let stdout = """
      account user@example.com failed
      ```json
      {"output":{"title":"Private customer work"}}
      ```
      see /Users/jerry/private.log
      """

    let sanitized = TelemetryErrorSanitizer.sanitizeFailureStdout(stdout)

    XCTAssertTrue(sanitized?.removedJSON ?? false)
    XCTAssertEqual(
      sanitized?.detail,
      "account <redacted-email> failed\n\nsee <redacted-path>"
    )
    XCTAssertFalse(sanitized?.detail?.contains("Private customer work") ?? true)
  }

  func testTelemetryFailureStdoutRemovesNonJSONBracesConservatively() {
    let stdout = "error: expected {model-name} after --model"

    let sanitized = TelemetryErrorSanitizer.sanitizeFailureStdout(stdout)

    XCTAssertTrue(sanitized?.removedJSON ?? false)
    XCTAssertEqual(sanitized?.detail, "error: expected after --model")
  }

  func testTelemetryFailureStdoutDropsTruncatedJSONLine() {
    let stdout = """
      warning before payload
      {"cards":[{"title":"Private customer work"
      retry after payload
      """

    let sanitized = TelemetryErrorSanitizer.sanitizeFailureStdout(stdout)

    XCTAssertTrue(sanitized?.removedJSON ?? false)
    XCTAssertEqual(sanitized?.detail, "warning before payload\n\nretry after payload")
    XCTAssertFalse(sanitized?.detail?.contains("Private customer work") ?? true)
  }

  func testClaudeSessionCleanupRemovesOnlyItsSessionTranscript() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent("Dayflow-Claude-OAuth-Test-\(UUID().uuidString)", isDirectory: true)
    let project = fixture.appendingPathComponent("projects/test-project", isDirectory: true)
    try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let sessionID = UUID().uuidString
    let sessionTranscript = project.appendingPathComponent("\(sessionID).jsonl")
    let unrelatedTranscript = project.appendingPathComponent("unrelated.jsonl")
    try Data("session".utf8).write(to: sessionTranscript)
    try Data("keep".utf8).write(to: unrelatedTranscript)

    let cleanup = ClaudeSessionCleanup(
      sessionID: sessionID,
      claudeConfigDirectory: fixture
    )

    cleanup.cleanup()

    XCTAssertFalse(fileManager.fileExists(atPath: sessionTranscript.path))
    XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTranscript.path))
  }

  private func card(
    start: String,
    end: String,
    category: String = "Focus",
    title: String
  ) -> ActivityCardData {
    ActivityCardData(
      startTime: start,
      endTime: end,
      category: category,
      subcategory: "",
      title: title,
      summary: "Summary",
      detailedSummary: "Details",
      distractions: nil,
      appSites: nil
    )
  }

  private func segment(
    start: String,
    end: String,
    description: String
  ) -> SegmentMergeResponse.Segment {
    SegmentMergeResponse.Segment(start: start, end: end, description: description)
  }
}
