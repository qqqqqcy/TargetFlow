import Foundation
import XCTest

@testable import Dayflow

/// Redacted replay of batch 251 / calls 509 and 510: preserve only schema and clock bounds.
final class TimelineFailure1937Tests: XCTestCase {
  private func epoch(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Int {
    Int(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30,
      hour: hour, minute: minute, second: second))!.timeIntervalSince1970)
  }

  private func card(_ start: String, _ end: String) -> ActivityCardData {
    ActivityCardData(startTime: start, endTime: end, category: "Idle", subcategory: "",
      title: "Synthetic event", summary: "Synthetic activity", detailedSummary: "",
      distractions: nil, appSites: nil)
  }

  private var screenshots: [Screenshot] {
    stride(from: epoch(19, 37, 20), through: epoch(19, 42, 20), by: 20).enumerated().map {
      Screenshot(id: Int64($0.offset), capturedAt: $0.element, filePath: "synthetic-unused",
        fileSize: nil, idleSecondsAtCapture: 0, isDeleted: false)
    }
  }

  private func context(previous: [ActivityCardData], connected: Bool) -> ActivityGenerationContext {
    ActivityGenerationContext(batchObservations: [], existingCards: previous,
      currentTime: Date(timeIntervalSince1970: Double(epoch(19, 43))), categories: [],
      hasPreviousCardWithinFiveMinutes: connected, hasContinuousCaptureBeforeBatch: connected)
  }

  private func response() throws -> String {
    // The saved response is an object with frames(time/app/note) and cards, not a bare array.
    // 15 image labels were returned from 16 captures; no source minute is missing.
    let selected = screenshots.enumerated().filter { $0.offset != 7 }.map(\.element)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm:ss a"
    let frames = selected.map { ["time": formatter.string(from: Date(timeIntervalSince1970: Double($0.capturedAt))),
      "app": "Synthetic app", "note": "Synthetic screen"] }
    let cards = [card("7:37 PM", "7:38 PM"), card("7:38 PM", "7:41 PM"), card("7:41 PM", "7:43 PM")]
    var cardObjects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cards)) as? [[String: Any]])
    for index in cardObjects.indices {
      cardObjects[index]["distractions"] = []
      cardObjects[index]["appSites"] = ["primary": "synthetic.invalid"]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["frames": frames, "cards": cardObjects]), as: UTF8.self)
  }

  func testSavedResponseAcrossDisconnectedHistoryPassesProductionBoundary() async throws {
    let previous = [card("6:04 PM", "7:03 PM"), card("7:03 PM", "7:10 PM")]
    let output = try response()
    var attempts = 0
    let result = try await TimelineEvidencePolicy.generate(screenshots: screenshots,
      context: context(previous: previous, connected: false), batchId: 251) { shots, runContext, _ in
        let frames = OneStepTimelineFrames(directory: URL(fileURLWithPath: "/tmp"),
          frames: shots.map { .init(capturedAt: $0.capturedAt, url: URL(fileURLWithPath: "/tmp/unused")) })
        let window = Observation(id: nil, batchId: 251, startTs: frames.windowStart,
          endTs: frames.windowEnd, observation: "", metadata: nil, llmModel: nil, createdAt: nil)
        let plan = TimelineOutputPolicy().makeClaudeCardGenerationPlan(observations: [window],
          context: ActivityGenerationContext(batchObservations: [window], existingCards: runContext.existingCards,
            currentTime: runContext.currentTime, categories: [],
            hasPreviousCardWithinFiveMinutes: runContext.hasPreviousCardWithinFiveMinutes))
        XCTAssertTrue(plan.context.existingCards.isEmpty)
        let parsed = try CodexProvider().parseCards(from: output, stderr: "Synthetic harmless diagnostic")
        try ClaudeOutputValidator.validateActivityCards(parsed, existingCards: plan.context.existingCards,
          observations: [window])
        attempts += 1
        if attempts == 1 { return (parsed, [], plan.rewriteSpan, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil)) }
        return ([self.card("7:37 PM", "7:43 PM")], [], plan.rewriteSpan,
          LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
      }
    XCTAssertEqual(result.cards.count, 1)
    XCTAssertEqual(result.cards.first?.startTime, "7:37 PM")
    XCTAssertEqual(result.cards.last?.endTime, "7:43 PM")
    let groups = try TimelineEvidencePolicy.replacementGroups(result.cards, nearest: epoch(19, 37))
    XCTAssertEqual(groups.map(\.range), [epoch(19, 37)..<epoch(19, 43)])
    XCTAssertTrue(result.observations.allSatisfy { $0.startTs >= epoch(19, 37) && $0.endTs <= epoch(19, 43) })
  }

  func testDisconnectedLookbackIsExcludedEvenWithFiveMinuteHint() async throws {
    let result = try await TimelineEvidencePolicy.generate(screenshots: screenshots,
      context: context(previous: [card("7:03 PM", "7:10 PM")], connected: true), batchId: 251) { _, runContext, _ in
        XCTAssertTrue(runContext.existingCards.isEmpty)
        XCTAssertFalse(runContext.hasPreviousCardWithinFiveMinutes)
        return ([self.card("7:37 PM", "7:43 PM")], [], nil,
          LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
      }
    XCTAssertEqual(result.cards.count, 1)
  }

  func testTypedCoverageFailureIsIndependentOfLocalizedDescription() {
    let classification = TimelineFailureClassifier.classify(ClaudeOutputValidationError.missingEvidenceCoverage)
    XCTAssertEqual(classification.kind, .timelineMismatch)
    XCTAssertNil(classification.toastContent(fallbackProviderLabel: "ChatGPT"))
    XCTAssertFalse(classification.cardMessage(fallbackProviderLabel: "ChatGPT").contains("automatically"))
    XCTAssertEqual(TimelineFailureClassifier.classify(
      ClaudeOutputValidationError.invalidCardDuration(title: "OAuth Synthetic", seconds: 0)).kind, .timelineMismatch)
  }

  func testFailureSummaryDoesNotPromiseAnUnscheduledRetry() {
    for kind in [TimelineFailureKind.transient, .modelFlaky, .unknown, .timelineMismatch,
      .providerLoginExpired, .usageLimitHit, .apiKeyProblem] {
      let message = TimelineFailureClassification(kind: kind, providerName: nil).cardMessage(fallbackProviderLabel: "ChatGPT")
      XCTAssertFalse(message.contains("automatically"))
    }
    let stored = "Something went wrong while turning this time into cards. Target Flow will try again automatically. Your recording is saved."
    let displayed = TimelineFailureClassifier.displaySummary(stored)
    XCTAssertFalse(displayed.contains("automatically"))
    XCTAssertEqual(displayed, String(localized:
      "This time couldn't be turned into events. You can retry this time. Your recording is saved."))
    XCTAssertFalse(TimelineFailureClassifier.displaySummary("Failed to process: PRIVATE SENTINEL").contains("PRIVATE SENTINEL"))
    XCTAssertEqual(TimelineFailureClassifier.displaySummary("Ordinary safe summary"), "Ordinary safe summary")
  }

  func testConnectedHistoryStillRequiresCoverage() async throws {
    do {
      _ = try await TimelineEvidencePolicy.generate(screenshots: screenshots,
        context: context(previous: [card("7:33 PM", "7:37 PM")], connected: true), batchId: 251) { _, runContext, _ in
          XCTAssertEqual(runContext.existingCards.count, 1)
          return ([self.card("7:37 PM", "7:43 PM")], [], nil,
            LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
        }
      XCTFail("Connected supported history must not be dropped")
    } catch {
      XCTAssertEqual(error as? ClaudeOutputValidationError, .missingEvidenceCoverage)
    }
  }

  func testDisconnectedHistoryCannotBeBridgedOrWholeMinuteOmitted() async throws {
    for generated in [card("7:10 PM", "7:43 PM"), card("7:38 PM", "7:43 PM")] {
      do {
        _ = try await TimelineEvidencePolicy.generate(screenshots: screenshots,
          context: context(previous: [card("7:03 PM", "7:10 PM")], connected: false), batchId: 251) { _, _, _ in
            ([generated], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
          }
        XCTFail("Must reject invented gap coverage or missing supported minute")
      } catch {
        XCTAssertTrue(error is ClaudeOutputValidationError)
      }
    }
  }
}
