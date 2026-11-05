import XCTest
@testable import Dayflow

/// Pure evidence planning tests; no storage, recorder, or model calls.
final class TimelineCaptureRunTests: XCTestCase {
  private var base: Int {
    Int(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!.timeIntervalSince1970)
  }

  private func frame(_ offset: Int, path: String = "old.mp4", index: Int? = nil,
    privateFrame: Bool = false) -> Screenshot {
    Screenshot(id: Int64(offset + 1), capturedAt: base + offset, filePath: path,
      fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false, frameIndex: index,
      isPrivacyRedacted: privateFrame)
  }

  private var context: ActivityGenerationContext {
    ActivityGenerationContext(batchObservations: [], existingCards: [], currentTime: Date(),
      categories: [], hasPreviousCardWithinFiveMinutes: false)
  }

  private func card(_ start: Int, _ end: Int) -> ActivityCardData {
    let policy = TimelineOutputPolicy()
    return ActivityCardData(startTime: policy.formatTimestampForPrompt(start),
      endTime: policy.formatTimestampForPrompt(end), category: "Idle", subcategory: "",
      title: "Synthetic activity", summary: "Synthetic facts", detailedSummary: "",
      distractions: nil, appSites: nil)
  }

  func testUnknownPartialRotationInSameMinuteSplitsButKnownTrueContinues() {
    let frames = [frame(0, index: 13), frame(20, index: 14), frame(40, path: "new.mp4", index: 0)]
    XCTAssertEqual(TimelineEvidencePolicy.captureRuns(frames, recordedContinuity: { _, _ in nil })
      .map { $0.map(\.id) }, [[1, 21], [41]])
    XCTAssertEqual(TimelineEvidencePolicy.captureRuns(frames, recordedContinuity: { _, _ in true }).count, 1)
    XCTAssertEqual(TimelineEvidencePolicy.captureRuns(frames, recordedContinuity: { _, next in
      next == self.base + 40 ? false : true
    }).map(\.count), [2, 1])
  }

  func testFiveMinuteHistoryIsInsufficientButDeterministicRotationRemains() {
    let history = stride(from: 0, through: 280, by: 20).enumerated().map {
      frame($0.element, index: $0.offset)
    }
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: history,
      next: frame(300, path: "new.mp4", index: 0)))
    let complete = stride(from: 0, through: 580, by: 20).enumerated().map {
      frame($0.element, index: $0.offset)
    }
    let next = frame(600, path: "new.mp4", index: 0)
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: complete, next: next))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: complete, next: next, recordedContinuity: false))
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(
      history: [frame(0, index: 0), frame(20, index: 598), frame(40, index: 599)],
      next: frame(60, path: "new.mp4", index: 0)))
  }

  func testSameMinuteRunsCallProviderSeparatelyAndOverwriteForgedSources() async throws {
    let frames = [frame(0, index: 13), frame(20, index: 14, privateFrame: true),
      frame(40, path: "new.mp4", index: 0)]
    var calls: [[Int64]] = []
    let ctx = ActivityGenerationContext(batchObservations: [], existingCards: [card(base - 60, base)],
      currentTime: Date(), categories: [], hasPreviousCardWithinFiveMinutes: true,
      hasContinuousCaptureBeforeBatch: true)
    let output = try await TimelineEvidencePolicy.generate(screenshots: frames, context: ctx,
      batchId: nil, recordedContinuity: { _, _ in nil }) { shots, context, _ in
      calls.append(shots.map(\.id))
      XCTAssertEqual(context.existingCards.count, calls.count == 1 ? 1 : 0)
      XCTAssertEqual(context.hasContinuousCaptureBeforeBatch, calls.count == 1)
      var generated = self.card(calls.count == 1 ? self.base - 60 : self.base, self.base + 60)
      generated.sourceScreenshotIDs = [999]
      return ([generated], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    }
    XCTAssertEqual(calls, [[1, 21], [41]])
    XCTAssertEqual(output.cards.count, 2)
    XCTAssertEqual(output.cards.map(\.sourceScreenshotIDs), [[1, 21], [41]])
    XCTAssertEqual(output.cards.map(\.evidenceKind), [.visible, .visible])
  }

  func testLegacyMinuteGapStillPartitionsAndStopsSplitSameFile() {
    let jpeg = [frame(0), frame(60), frame(180)]
    let spans = TimelineEvidencePolicy.captureRuns(jpeg, recordedContinuity: { _, _ in nil })
      .flatMap { TimelineEvidencePolicy.partition($0) }
    XCTAssertEqual(spans.map(\.startTs), [base, base + 180])
    XCTAssertEqual(spans.map(\.endTs), [base + 120, base + 240])
    XCTAssertEqual(TimelineEvidencePolicy.captureRuns([frame(0, index: 0), frame(20, index: 1)],
      recordedContinuity: { _, _ in false }).count, 2)
  }

  func testDuplicateTimestampsSplitEvenWhenEarlierFrameCouldLookAdjacent() {
    let frames = [frame(0, index: 0), frame(20, index: 1), frame(20, index: 1)]
    XCTAssertEqual(TimelineEvidencePolicy.captureRuns(frames, recordedContinuity: { _, _ in true })
      .map(\.count), [2, 1])
  }

  func testFourAMSplitsEvenWithKnownContinuity() {
    let boundary = Int(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 4))!.timeIntervalSince1970)
    let frames = [frame(boundary - base - 10, index: 0), frame(boundary - base + 10, index: 1)]
    XCTAssertEqual(TimelineEvidencePolicy.captureRuns(frames, recordedContinuity: { _, _ in true }).count, 2)
  }

  func testSourceMetadataCannotEnterOrLeaveModelJSON() throws {
    var original = card(base, base + 60)
    original.sourceScreenshotIDs = [1, 2]
    let encoded = try JSONEncoder().encode(original)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sourceScreenshotIDs"))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["sourceScreenshotIDs"] = [999]
    let forged = try JSONSerialization.data(withJSONObject: object)
    XCTAssertNil(try JSONDecoder().decode(ActivityCardData.self, from: forged).sourceScreenshotIDs)
  }

  func testTouchingCardsFromDifferentRunsDoNotShareReplacementGroup() throws {
    var first = card(base, base + 60)
    var second = card(base + 60, base + 120)
    first.sourceScreenshotIDs = [1]
    second.sourceScreenshotIDs = [2]
    XCTAssertEqual(try TimelineEvidencePolicy.replacementGroups([first, second], nearest: base).count, 2)
  }
}
