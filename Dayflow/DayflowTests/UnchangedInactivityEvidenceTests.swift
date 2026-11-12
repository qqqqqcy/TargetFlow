import XCTest
@testable import Dayflow

final class UnchangedInactivityEvidenceTests: XCTestCase {
  private func frames(_ times: [Int], privacy: Bool = false) -> [Screenshot] {
    times.map { Screenshot(id: Int64($0), capturedAt: $0, filePath: "/synthetic", fileSize: nil,
      idleSecondsAtCapture: $0 + 60, isDeleted: false, isPrivacyRedacted: privacy) }
  }
  private let pixels = [UInt8](repeating: 100, count: 96 * 54)

  private func assess(end: Int, threshold: Int, evidenceSince: Int? = nil) -> IdleBatchAssessment? {
    let all = frames(Array(stride(from: 0, through: end, by: 1)))
    let batch = all.filter { $0.capturedAt >= end - 60 }
    let history = all.filter { $0.capturedAt < end - 60 }
    return IdleBatchClassifier.assess(batch, history: history, evidenceSince: evidenceSince,
      thresholdSeconds: threshold, pixels: { _ in self.pixels })
  }

  func testEachThresholdJustBelowAndAtBoundaryAcrossShortBatches() {
    for threshold in InactivityPreferences.thresholdOptions {
      XCTAssertNil(assess(end: threshold - 1, threshold: threshold))
      let result = assess(end: threshold, threshold: threshold)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.thresholdSeconds, threshold)
      XCTAssertEqual(result?.batchDurationSeconds, 60)
    }
  }

  func testFirstEligibleFiveMinuteBatchMatchesSelectedDuration() {
    let all = frames(Array(stride(from: 0, through: 1200, by: 10)))
    for threshold in InactivityPreferences.thresholdOptions {
      let firstStart = stride(from: 0, through: 900, by: 300).first { start in
        let batch = all.filter { $0.capturedAt >= start && $0.capturedAt <= start + 300 }
        let history = all.filter { $0.capturedAt < start }
        let assessment = IdleBatchClassifier.assess(
          batch, history: history, thresholdSeconds: threshold, pixels: { _ in self.pixels })
        return assessment != nil
      }
      let firstEnd = firstStart.map { $0 + 300 }
      XCTAssertEqual(firstEnd, threshold)
    }
  }

  func testRuntimePreferenceChangeAppliesToFutureDecisions() {
    let suite = "RuntimeInactivity.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = assess(end: 300, threshold: InactivityPreferences.thresholdSeconds(in: defaults))
    XCTAssertNotNil(original)
    InactivityPreferences.setThresholdSeconds(900, in: defaults)
    XCTAssertNil(assess(end: 600, threshold: InactivityPreferences.thresholdSeconds(in: defaults)))
    XCTAssertNotNil(assess(end: 900, threshold: InactivityPreferences.thresholdSeconds(in: defaults)))
    XCTAssertEqual(original?.thresholdSeconds, 300)
    InactivityPreferences.setThresholdSeconds(600, in: defaults)
    XCTAssertNotNil(assess(end: 600, threshold: InactivityPreferences.thresholdSeconds(in: defaults)))
  }

  func testBlackFramesUseOrdinaryImageAndInputEvidence() {
    for threshold in InactivityPreferences.thresholdOptions {
      var decodes = 0
      let history = frames(Array(stride(from: 0, to: threshold - 60, by: 60)), privacy: true)
      let batch = frames([threshold - 60, threshold])
      XCTAssertNotNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: threshold, pixels: { _ in
        decodes += 1; return self.pixels
      }))
      XCTAssertGreaterThan(decodes, 0)
      let blackBatch = frames([threshold - 60, threshold], privacy: true)
      XCTAssertNotNil(IdleBatchClassifier.assess(blackBatch,
        history: history, thresholdSeconds: threshold, pixels: { _ in self.pixels }))
      XCTAssertNil(IdleBatchClassifier.assess(blackBatch,
        history: history, thresholdSeconds: threshold, pixels: { $0.capturedAt == threshold ? nil : self.pixels }))
      XCTAssertNil(IdleBatchClassifier.assess(blackBatch,
        history: history, thresholdSeconds: threshold, pixels: {
          $0.capturedAt == threshold ? [UInt8](repeating: 200, count: self.pixels.count) : self.pixels
        }))
    }
  }

  func testDynamicVideoCorruptionInputResetAndCaptureGapBreakEvidence() {
    for threshold in InactivityPreferences.thresholdOptions {
      let history = frames(Array(stride(from: 0, to: threshold - 60, by: 60)))
      let batch = frames([threshold - 60, threshold])
      XCTAssertNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: threshold, pixels: {
        $0.capturedAt == 120 ? [UInt8](repeating: 200, count: self.pixels.count) : self.pixels
      }))
      XCTAssertNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: threshold, pixels: {
        $0.capturedAt == 120 ? nil : self.pixels
      }))
      XCTAssertNil(IdleBatchClassifier.assess(batch,
        history: history.filter { $0.capturedAt != 120 }, thresholdSeconds: threshold, pixels: { _ in self.pixels }))
      var reset = history
      reset[2] = Screenshot(id: 120, capturedAt: 120, filePath: "/synthetic", fileSize: nil,
        idleSecondsAtCapture: 0, isDeleted: false)
      XCTAssertNil(IdleBatchClassifier.assess(batch, history: reset, thresholdSeconds: threshold,
        pixels: { _ in self.pixels }))
      let unknownInput = batch.map { Screenshot(id: $0.id, capturedAt: $0.capturedAt,
        filePath: "/synthetic", fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false) }
      XCTAssertNil(IdleBatchClassifier.assess(unknownInput, history: history, thresholdSeconds: threshold,
        pixels: { _ in self.pixels }))
      XCTAssertNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: threshold, pixels: {
        $0.capturedAt == threshold ? nil : self.pixels
      }))
    }
  }

  func testSimilarityToleratesTinyClockChangeButRejectsLargeContentChange() {
    var clock = pixels
    clock[0] = 120
    XCTAssertTrue(IdleBatchClassifier.isSimilar(pixels, clock))
    XCTAssertFalse(IdleBatchClassifier.isSimilar(pixels, [UInt8](repeating: 150, count: pixels.count)))
    XCTAssertFalse(IdleBatchClassifier.isSimilar([], []))
  }

  func testDenseOneSecondCaptureAndMaximumSupportedBatchRemainEligible() {
    for threshold in InactivityPreferences.thresholdOptions {
      let lookback = IdleBatchRules.historyLookbackSeconds(thresholdSeconds: threshold)
      let history = frames(Array(0..<lookback))
      let batch = frames(Array(lookback...(lookback + 900)))
      XCTAssertLessThanOrEqual(history.count + batch.count, IdleBatchRules.maximumComparedFrames)
      XCTAssertNotNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: threshold,
        pixels: { _ in self.pixels }))
      XCTAssertNil(IdleBatchClassifier.assess(batch.filter { !(lookback + 100...lookback + 110).contains($0.capturedAt) },
        history: history, thresholdSeconds: threshold, pixels: { _ in self.pixels }))
    }
  }

  func testHistoricalUnknownProvenanceCannotQualifyAfterLaunchCutoff() {
    for threshold in InactivityPreferences.thresholdOptions {
      XCTAssertNotNil(assess(end: threshold, threshold: threshold))
      XCTAssertNil(assess(end: threshold, threshold: threshold, evidenceSince: 1))
      XCTAssertNil(assess(end: threshold, threshold: threshold, evidenceSince: threshold + 1))
    }
  }

  func testUnsupportedThresholdDoesNotQualify() {
    XCTAssertNil(assess(end: 900, threshold: 720))
  }

  func testPrivacyUnknownAndUnmatchedDoNotCountAsConfiguredGoalFocus() {
    let goal = TimelineCategory(name: "Goal A", colorHex: "#FF0000", order: 0, targetEnabled: true)
    let snapshots = [DayGoalCategorySnapshot(category: goal, sortOrder: 0)]
    for (category, evidence) in [("Goal A", ActivityEvidenceKind.privacyRedacted),
      ("Goal A", .unknown), ("__unmatched__", .visible)] {
      let card = TimelineCard(recordId: 1, batchId: 1, startTimestamp: "10:00 AM", endTimestamp: "10:05 AM",
        category: category, subcategory: "", title: "Synthetic", summary: "", detailedSummary: "",
        day: "2026-10-30", distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil,
        appSites: nil, evidenceKind: evidence)
      XCTAssertEqual(DaySummaryStats.computeTotalFocusTime(
        from: DaySummaryStats.precomputeCardDurations([card]), snapshots: snapshots, categories: [goal]), 0)
    }
  }

  func testReservedLabelsNeverBorrowConfiguredGoalColor() {
    XCTAssertEqual(TimelineEventDisplay.reservedCategory("__unmatched__")?.name, String(localized: "Other"))
    XCTAssertEqual(TimelineEventDisplay.reservedCategory("__unmatched__")?.isIdle, true)
    XCTAssertEqual(TimelineEventDisplay.reservedCategory("__privacy__")?.name, String(localized: "Other"))
    XCTAssertEqual(TimelineEventDisplay.reservedCategory("Idle")?.isIdle, true)
    XCTAssertEqual(TimelineEventDisplay.reservedCategory("__unmatched__")?.colorHex, "#A0AEC0")
  }
}
