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

  func testVisibleBlackVisibleUsesOneRequestAndContinuousPriorContext() async throws {
    var calls: [[Int64]] = []
    let shots = [shot(0), shot(1), shot(2, privateFrame: true), shot(3, privateFrame: true), shot(4), shot(5)]
    let output = try await TimelineEvidencePolicy.generate(screenshots: shots,
      context: { var value = context([card("8:59 AM", "9:00 AM", "Earlier A")]); value.hasContinuousCaptureBeforeBatch = true; return value }(), batchId: 42) { frames, ctx, _ in
      calls.append(frames.map(\.id))
      XCTAssertEqual(frames.filter(\.isPrivacyRedacted).map(\.id), [120, 180])
      XCTAssertEqual(ctx.existingCards.map(\.title), ["Earlier A"])
      XCTAssertTrue(ctx.hasContinuousCaptureBeforeBatch)
      return self.result([self.card("8:59 AM", "9:06 AM", "Continued work with a redacted interval")])
    }
    XCTAssertEqual(calls, [[0, 60, 120, 180, 240, 300]])
    XCTAssertEqual(output.cards.count, 1)
    XCTAssertTrue(output.cards[0].detailedSummary.contains("Earlier A"))
    XCTAssertEqual(output.cards[0].title, "Continued work with a redacted interval")
    XCTAssertEqual(output.cards[0].evidenceKind, .visible)
    XCTAssertEqual(output.rewriteSpan, (anchor - 60)..<(anchor + 360))
  }

  func testBlackOnlyBatchCallsProviderWithoutInferringHiddenContent() async throws {
    var calls = 0
    let output = try await TimelineEvidencePolicy.generate(
      screenshots: [shot(0, privateFrame: true), shot(1, privateFrame: true)],
      context: context(), batchId: nil) { frames, _, _ in
        calls += 1
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy(\.isPrivacyRedacted))
        return self.result([self.card("9:00 AM", "9:02 AM", "Black frames; activity unavailable")])
      }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(output.cards.count, 1)
    XCTAssertEqual(output.cards[0].title, "Black frames; activity unavailable")
    XCTAssertEqual(output.cards[0].evidenceKind, .visible)
  }

  func testRedactionDoesNotPartitionMinutesButCaptureGapsRemain() {
    let spans = TimelineEvidencePolicy.partition([
      shot(0), shot(0, privateFrame: true, seconds: 40), shot(1), shot(5)])
    XCTAssertEqual(spans.map(\.kind), [.visible, .visible])
    XCTAssertEqual(spans.map(\.startTs), [anchor, anchor + 300])
    XCTAssertEqual(spans.map(\.endTs), [anchor + 120, anchor + 360])
    XCTAssertEqual(spans[0].screenshots.map(\.id), [0, 40, 60])
  }

  func testBlackFrameProviderFailurePropagatesWithoutLocalCard() async throws {
    let failure = NSError(domain: "SyntheticProvider", code: 503)
    var calls = 0
    do {
      _ = try await TimelineEvidencePolicy.generate(screenshots: [shot(0), shot(1, privateFrame: true)],
        context: context(), batchId: nil) { frames, _, _ in
          calls += 1
          XCTAssertEqual(frames.count, 2)
          throw failure
        }
      XCTFail("Provider failure must propagate")
    } catch {
      XCTAssertEqual((error as NSError).domain, failure.domain)
      XCTAssertEqual((error as NSError).code, failure.code)
    }
    XCTAssertEqual(calls, 1)
  }

  func testProviderRedactionProseDoesNotCreateLocalPrivacyStatus() async throws {
    let output = try await TimelineEvidencePolicy.generate(screenshots: [shot(0), shot(1, privateFrame: true), shot(2)],
      context: context(), batchId: nil) { _, _, _ in
        self.result([self.card("9:00 AM", "9:03 AM", "Content hidden by privacy settings", evidence: .inputInactive)])
      }
    XCTAssertEqual(output.cards.count, 1)
    XCTAssertEqual(output.cards[0].evidenceKind, .visible)
    XCTAssertEqual(output.cards[0].title, "Content hidden by privacy settings")
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

  func testLeadingBlackFrameRewritesContinuousLegacyPrivacyContext() async throws {
    var ctx = context([card("8:57 AM", "9:00 AM", "Earlier work", evidence: .privacyRedacted)])
    ctx.hasContinuousCaptureBeforeBatch = true
    let output = try await TimelineEvidencePolicy.generate(screenshots: [shot(0, privateFrame: true)],
      context: ctx, batchId: nil) { frames, context, _ in
        XCTAssertTrue(frames[0].isPrivacyRedacted)
        XCTAssertEqual(context.existingCards.map(\.title), ["Earlier work"])
        XCTAssertEqual(context.existingCards.first?.evidenceKind, .privacyRedacted)
        return self.result([self.card("8:57 AM", "9:01 AM", "Continued context with redaction")])
      }
    XCTAssertEqual(output.cards.map(\.endTime), ["9:01 AM"])
    XCTAssertEqual(output.cards.map(\.title), ["Continued context with redaction"])
    XCTAssertTrue(output.cards[0].detailedSummary.contains("Earlier work"))
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
