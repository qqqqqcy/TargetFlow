import XCTest

@testable import Dayflow

final class ActivityBoundaryTests: XCTestCase {
  private let policy = TimelineOutputPolicy()
  private var anchor: Int {
    Int(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!.timeIntervalSince1970)
  }
  private func card(_ start: String, _ end: String, _ title: String,
    distractions: [Distraction]? = nil, evidence: ActivityEvidenceKind? = nil) -> ActivityCardData {
    ActivityCardData(startTime: start, endTime: end, category: "Goal A", subcategory: "",
      title: title, summary: title, detailedSummary: "", distractions: distractions,
      appSites: nil, evidenceKind: evidence)
  }
  private func shot(_ minute: Int, privateFrame: Bool = false, seconds: Int = 0) -> Screenshot {
    Screenshot(id: Int64(minute * 60 + seconds), capturedAt: anchor + minute * 60 + seconds,
      filePath: "/synthetic/unused.jpg", fileSize: nil, idleSecondsAtCapture: 999,
      isDeleted: false, isPrivacyRedacted: privateFrame)
  }
  private func context(_ previous: [ActivityCardData] = []) -> ActivityGenerationContext {
    ActivityGenerationContext(batchObservations: [], existingCards: previous,
      currentTime: Date(timeIntervalSince1970: Double(anchor + 3600)), categories: [],
      hasPreviousCardWithinFiveMinutes: !previous.isEmpty)
  }
  private func result(_ cards: [ActivityCardData]) -> TimelineEvidencePolicy.Result {
    (cards, [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
  }

  func testDistinctShortEventsPassStructuralValidationAnywhere() throws {
    let cards = [card("9:00 AM", "9:04 AM", "A"), card("9:04 AM", "9:08 AM", "B"),
      card("9:08 AM", "9:09 AM", "C")]
    let window = Observation(id: nil, batchId: 1, startTs: anchor, endTs: anchor + 540,
      observation: "A then B then C", metadata: nil, llmModel: nil, createdAt: nil)
    try ClaudeOutputValidator.validateActivityCards(cards, existingCards: [], observations: [window])
    XCTAssertTrue(policy.validateTimeline(cards).isValid)
    XCTAssertTrue(ClaudeProvider().validateClaudeCardPolicy(cards, requiresSingleCard: true,
      expectedStartTime: "9:00 AM", expectedEndTime: "9:09 AM", allowsSingleShortCard: false).isValid)
  }

  func testUnknownLabelsNeverUseFirstConfiguredEvent() {
    let a = LLMCategoryDescriptor(id: UUID(), name: "Goal A", colorHex: "#FFFFFF",
      description: nil, isSystem: false, isIdle: false)
    let b = LLMCategoryDescriptor(id: UUID(), name: "Goal B", colorHex: "#FFFFFF",
      description: nil, isSystem: false, isIdle: false)
    for definitions in [[a, b], [b, a], []] {
      for raw in ["", " ", "Unrelated C", "__unmatched__"] {
        XCTAssertEqual(policy.normalizeCategory(raw, descriptors: definitions), "Idle")
        XCTAssertEqual(GeminiDirectProvider(apiKey: "synthetic").normalizeCategory(raw,
          descriptors: definitions), "Idle")
      }
    }
    XCTAssertEqual(policy.normalizeCategory(" goal a ", descriptors: [a]), "Goal A")
  }

  func testValidNestedDistractionBecomesIndependentEvent() throws {
    let nested = Distraction(startTime: "9:04 AM", endTime: "9:07 AM", title: "Read sports",
      summary: "Read sports results.")
    let cards = TimelineEvidencePolicy.splitDistractions([
      card("9:00 AM", "9:12 AM", "Fix login", distractions: [nested])], nearest: anchor)
    XCTAssertEqual(cards.map(\.title), ["Fix login", "Read sports", "Fix login"])
    XCTAssertEqual(cards.map(\.startTime), ["9:00 AM", "9:04 AM", "9:07 AM"])
    XCTAssertEqual(cards.map(\.endTime), ["9:04 AM", "9:07 AM", "9:12 AM"])
    XCTAssertEqual(cards[1].category, "Idle")
    XCTAssertTrue(cards.allSatisfy { $0.distractions == nil })
    try ClaudeOutputValidator.validateActivityCards(cards, existingCards: [], observations: [])
  }

  func testInvalidNestedIntervalsAreNotInventedOrBorrowed() {
    let invalid = Distraction(startTime: "9:11 AM", endTime: "9:20 AM", title: "B", summary: "B")
    let output = TimelineEvidencePolicy.splitDistractions([
      card("9:00 AM", "9:12 AM", "A", distractions: [invalid])], nearest: anchor)
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0].distractions?.count, 1)
  }

  func testPrivacyRunsBypassProviderAndCannotBridgePriorCards() async throws {
    var calls: [[Int64]] = []
    let shots = [shot(0), shot(1), shot(2, privateFrame: true), shot(3, privateFrame: true), shot(4), shot(5)]
    let output = try await TimelineEvidencePolicy.generate(screenshots: shots,
      context: { var value = context([card("8:59 AM", "9:00 AM", "Earlier A")]); value.hasContinuousCaptureBeforeBatch = true; return value }(), batchId: 42) { frames, ctx, _ in
      calls.append(frames.map(\.id))
      XCTAssertFalse(frames.contains(where: \.isPrivacyRedacted))
      XCTAssertFalse(ctx.existingCards.contains(where: TimelineEvidencePolicy.containsLegacyPrivacyMarker))
      if calls.count == 1 {
        return self.result([self.card("8:59 AM", "9:02 AM", "A")])
      }
      XCTAssertTrue(ctx.existingCards.isEmpty)
      return self.result([self.card("9:04 AM", "9:06 AM", "B")])
    }
    XCTAssertEqual(calls, [[0, 60], [240, 300]])
    XCTAssertTrue(output.cards[0].detailedSummary.contains("Earlier A"))
    XCTAssertTrue(output.cards[0].title.contains("A"))
    XCTAssertEqual(output.cards[1].title, "Privacy protected")
    XCTAssertEqual(output.cards[2].title, "B")
    XCTAssertEqual(output.cards.map(\.evidenceKind), [.visible, .privacyRedacted, .visible])
    XCTAssertEqual(output.cards[1].category, "__privacy__")
    XCTAssertNil(output.cards[1].appSites)
    XCTAssertEqual(output.cards[1].detailedSummary, "")
    XCTAssertEqual(output.rewriteSpan, (anchor - 60)..<(anchor + 360))
    XCTAssertFalse(output.observations.contains { $0.startTs < anchor + 240 && $0.endTs > anchor + 120 })
  }

  func testFullyPrivateBatchNeverCallsProvider() async throws {
    let output = try await TimelineEvidencePolicy.generate(
      screenshots: [shot(0, privateFrame: true), shot(1, privateFrame: true)],
      context: context(), batchId: nil) { _, _, _ in
        XCTFail("Private pixels must not leave local processing")
        return self.result([])
      }
    XCTAssertEqual(output.cards.count, 1)
    XCTAssertEqual(output.cards[0].evidenceKind, .privacyRedacted)
    XCTAssertTrue(output.observations.isEmpty)
  }

  func testAnyPrivateCaptureProtectsWholeMinuteAndGapsRemain() {
    let spans = TimelineEvidencePolicy.partition([
      shot(0), shot(0, privateFrame: true, seconds: 40), shot(1), shot(5)])
    XCTAssertEqual(spans.map(\.kind), [.privacyRedacted, .visible, .visible])
    XCTAssertEqual(spans.map(\.startTs), [anchor, anchor + 60, anchor + 300])
    XCTAssertEqual(spans.map(\.endTs), [anchor + 60, anchor + 120, anchor + 360])
  }

  func testProviderCannotCrossTypedPrivacyBarrier() async throws {
    do {
      _ = try await TimelineEvidencePolicy.generate(screenshots: [shot(0), shot(1, privateFrame: true)],
        context: context(), batchId: nil) { _, _, _ in
          self.result([self.card("9:00 AM", "9:02 AM", "Forged work")])
        }
      XCTFail("Provider extended work across withheld evidence")
    } catch { XCTAssertNotNil(error as? ClaudeOutputValidationError) }
  }

  func testProviderProvenanceCannotForgeInactivityAndLocalPrivacySurvives() async throws {
    let nested = Distraction(startTime: "9:01 AM", endTime: "9:02 AM",
      title: "privacy placeholder", summary: "隐私设置遮挡 secret app name")
    let output = try await TimelineEvidencePolicy.generate(screenshots: [shot(0), shot(1), shot(2)],
      context: context(), batchId: nil) { _, _, _ in
        self.result([self.card("9:00 AM", "9:03 AM", "A", distractions: [nested], evidence: .inputInactive)])
      }
    XCTAssertEqual(output.cards.map(\.evidenceKind), [.visible, .privacyRedacted, .visible])
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(output.cards), as: UTF8.self).contains("secret app"))
  }

  func testLegacyAndEnvelopeParsingPreserveOptionalMetadata() throws {
    for kind in [ActivityEvidenceKind.visible, .privacyRedacted, .inputInactive, .unknown] {
      let original = card("9:00 AM", "9:04 AM", "A", evidence: kind)
      let data = try JSONEncoder().encode([original])
      XCTAssertEqual(try JSONDecoder().decode([ActivityCardData].self, from: data)[0].evidenceKind, kind)
      let envelope = "{\"cards\":" + String(decoding: data, as: UTF8.self) + "}"
      XCTAssertEqual(try CodexProvider().parseCards(from: envelope, stderr: "")[0].evidenceKind, kind)
      XCTAssertEqual(policy.normalizeCards([original], descriptors: [])[0].evidenceKind, kind)
    }
    let old = #"[{"startTime":"9:00 AM","endTime":"9:04 AM","category":"Work","subcategory":"","title":"A","summary":"A","detailedSummary":""}]"#
    XCTAssertNil(try JSONDecoder().decode([ActivityCardData].self, from: Data(old.utf8))[0].evidenceKind)
  }

  func testEveryProviderRejectsPrivateFramesAndLegacyProtectedContextBeforeTransport() async throws {
    let configuration = OpenAICompatibleRuntimeConfiguration(
      configuration: .init(preset: .custom, baseURL: "https://example.invalid/v1", modelID: "synthetic"), bearerToken: nil)
    let providers: [AIConfiguredProvider] = [.codex(CodexProvider()), .claude(ClaudeProvider()),
      .gemini(GeminiDirectProvider(apiKey: "synthetic")),
      .compatible(OpenAICompatibleProvider(configuration: configuration)),
      .local(OllamaProvider(openAICompatible: configuration)),
      .hosted(DayflowBackendProvider(token: "synthetic", endpoint: "https://example.invalid"))]
    for provider in providers {
      do {
        _ = try await provider.generateTimeline(screenshots: [shot(0, privateFrame: true)],
          context: context(), batchId: nil)
        XCTFail("Private timeline reached transport")
      } catch { XCTAssertEqual((error as NSError).domain, "TimelineEvidence") }
      do {
        _ = try await provider.transcribeScreenshots([shot(0, privateFrame: true)],
          batchStartTime: Date(timeIntervalSince1970: Double(anchor)), batchId: nil)
        XCTFail("Private transcription reached transport")
      } catch { XCTAssertEqual((error as NSError).domain, "TimelineEvidence") }
      do {
        _ = try await provider.generateActivityCards(observations: [],
          context: context([card("9:00 AM", "9:01 AM", "Protected", evidence: .privacyRedacted)]), batchId: nil)
        XCTFail("Protected legacy context reached transport")
      } catch { XCTAssertEqual((error as NSError).domain, "TimelineEvidence") }
    }
  }

  func testReplacementGroupsDoNotDeleteUnobservedGap() async throws {
    let output = try await TimelineEvidencePolicy.generate(screenshots: [shot(0), shot(2)],
      context: context(), batchId: nil) { frames, _, _ in
        let minute = (frames[0].capturedAt - self.anchor) / 60
        return self.result([self.card(minute == 0 ? "9:00 AM" : "9:02 AM",
          minute == 0 ? "9:01 AM" : "9:03 AM", "Visible")])
      }
    let groups = try TimelineEvidencePolicy.replacementGroups(output.cards, nearest: anchor)
    XCTAssertEqual(groups.map(\.range), [anchor..<(anchor + 60), (anchor + 120)..<(anchor + 180)])
  }

  func testLeadingPrivateMinutePreservesPreviousVisiblePrefix() async throws {
    let output = try await TimelineEvidencePolicy.generate(screenshots: [shot(0, privateFrame: true)],
      context: context([card("8:57 AM", "9:01 AM", "Earlier work")]), batchId: nil) { _, _, _ in
        XCTFail("No visible input")
        return self.result([])
      }
    XCTAssertEqual(output.cards.map(\.endTime), ["9:00 AM", "9:01 AM"])
    XCTAssertEqual(output.cards.map(\.title), ["Earlier work", "Privacy protected"])
  }

  func testGenerationAndRepairPromptsPreserveShortPurposes() {
    let claude = ClaudeProvider()
    let codex = CodexProvider()
    let prompts = [ClaudeTimelinePrompt.template, claude.buildCardsPrompt(observations: [], context: context()),
      claude.buildCardsCorrectionPrompt(validationError: "coverage", requiresSingleCard: true),
      codex.buildCardsPrompt(observations: [], context: context()), codex.buildCardsCorrectionPrompt(validationError: "coverage")]
    for prompt in prompts {
      XCTAssertFalse(prompt.contains("must be 10"))
      XCTAssertFalse(prompt.contains("EXACTLY ONE CARD"))
      XCTAssertFalse(prompt.contains("duration rule overrides"))
    }
  }
}
