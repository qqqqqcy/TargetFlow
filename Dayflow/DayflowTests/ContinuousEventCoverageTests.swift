import Foundation
import XCTest
@testable import Dayflow

final class ContinuousEventCoverageTests: XCTestCase {
  private let base = 1_804_000_020 / 60 * 60 + 7

  @MainActor
  func testBriefDifferentLabelIsAbsorbedWithoutUnpublishedHole() async throws {
    try await checkPublication(mode: .briefSwitch)
  }

  @MainActor
  func testStableDifferentEventsShareOneExactBoundary() async throws {
    try await checkPublication(mode: .stableSwitch)
  }

  func testChangedWindowRestabilizesBeforeCommitWithoutCrossingRuns() throws {
    let clock = TimelineOutputPolicy()
    let minute = base / 60 * 60
    func card(_ offset: Int, _ category: String, _ ids: [Int64]) -> ActivityCardData {
      var card = ActivityCardData(startTime: clock.formatTimestampForPrompt(minute + offset),
        endTime: clock.formatTimestampForPrompt(minute + offset + 360), category: category,
        subcategory: "", title: category, summary: category + " evidence", detailedSummary: category + " detail",
        distractions: nil, appSites: nil)
      card.sourceScreenshotIDs = ids
      return card
    }
    let a = card(0, "Work", [1, 2])
    let b = card(360, "Personal", [1, 2])
    let afterStop = card(720, "Personal", [3, 4])
    let revised = try TimelineStabilizedCommit.cards([a, b, afterStop], nearest: minute, minimum: 900)
    XCTAssertEqual(revised.count, 2)
    XCTAssertEqual(revised[0].category, "Work")
    XCTAssertEqual(revised[0].sourceScreenshotIDs, [1, 2])
    XCTAssertTrue(revised[0].detailedSummary.contains("Personal detail"))
    XCTAssertEqual(revised[1].sourceScreenshotIDs, [3, 4])
    XCTAssertEqual(revised[1].startTime, afterStop.startTime)
  }

  private enum Mode { case briefSwitch, stableSwitch }

  @MainActor
  private func checkPublication(mode: Mode) async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = prior
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    let path = "continuous-events-\(UUID().uuidString)"
    let duration = mode == .briefSwitch ? 840 : 720
    let batch = try storage.timedWrite("continuous coverage setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + duration])
      let batch = db.lastInsertedRowID
      for offset in stride(from: 0, through: duration, by: 20) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index) VALUES (?,?,?)", arguments: [base + offset, path, offset / 20])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
      }
      return batch
    }
    var extraBatch: Int64?
    defer { try? storage.timedWrite("continuous coverage cleanup") { db in
      for id in [batch, extraBatch].compactMap({ $0 }) {
        try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [id])
        try db.execute(sql: "DELETE FROM pending_timeline_evidence WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let selection = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: selection)])
    let output = TimelineOutputPolicy()
    let minute = base / 60 * 60
    let end = (base + duration) / 60 * 60 + 60
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      calls += 1
      func card(_ start: Int, _ end: Int, _ label: String, _ detail: String) -> ActivityCardData {
        ActivityCardData(startTime: output.formatTimestampForPrompt(start), endTime: output.formatTimestampForPrompt(end),
          category: label, subcategory: "", title: "Synthetic work session", summary: "Work progressed; a brief message was checked.",
          detailedSummary: detail, distractions: nil, appSites: nil)
      }
      let cards: [ActivityCardData]
      if mode == .stableSwitch {
        cards = [card(minute, minute + 360, "Work", "WORK_EVIDENCE"),
          card(minute + 360, end, "Personal", "PERSONAL_EVIDENCE")]
      } else if context.correctionCards.isEmpty && calls == 1 {
        cards = [card(minute, minute + 360, "Work", "WORK_EVIDENCE"),
          card(minute + 360, minute + 480, "Personal", "BRIEF_MESSAGE_EVIDENCE"),
          card(minute + 480, end, "Work", "MORE_WORK_EVIDENCE")]
      } else {
        cards = [card(minute, end, "Work", "WORK_EVIDENCE\nBRIEF_MESSAGE_EVIDENCE\nMORE_WORK_EVIDENCE")]
      }
      return (cards, [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch) { continuation.resume(returning: $0) }
    }
    let saved = try result.get().cardIds.compactMap { storage.fetchTimelineCard(byId: $0) }
      .sorted { $0.startTs < $1.startTs }
    XCTAssertEqual(saved.first?.startTs, base)
    XCTAssertEqual(saved.last?.endTs, base + duration)
    for (left, right) in zip(saved, saved.dropFirst()) {
      XCTAssertEqual(left.endTs, right.startTs, "Continuous capture must not leave a sampling interval blank")
      XCTAssertEqual(left.endTimestamp, right.startTimestamp,
        "Shared exact seams must also stay touching in the next model's minute-clock context")
    }
    XCTAssertTrue(storage.pendingTimelineEvidence().filter { $0.batchId == batch }.isEmpty)
    if mode == .briefSwitch {
      XCTAssertEqual(saved.count, 1)
      XCTAssertEqual(saved.first?.category, "Work")
      XCTAssertTrue(saved.first?.detailedSummary.contains("BRIEF_MESSAGE_EVIDENCE") == true)
    } else {
      XCTAssertEqual(saved.map(\.category), ["Work", "Personal"])
      let exactSeam = saved[0].endTs
      extraBatch = try storage.timedWrite("continuous next batch") { db -> Int64 in
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)",
          arguments: [base + duration + 20, base + duration + 320])
        let id = db.lastInsertedRowID
        for offset in stride(from: duration + 20, through: duration + 320, by: 20) {
          try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index) VALUES (?,?,?)", arguments: [base + offset, path, offset / 20])
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
        }
        return id
      }
      let continuedService = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, context, _ in
        XCTAssertEqual(context.existingCards.map(\.category), ["Work", "Personal"])
        let historicalLeft = try XCTUnwrap(context.existingCards.first)
        let historicalRight = try XCTUnwrap(context.existingCards.last)
        let right = ActivityCardData(startTime: historicalRight.startTime,
          endTime: output.formatTimestampForPrompt(try XCTUnwrap(frames.last).capturedAt / 60 * 60 + 60),
          category: "Personal", subcategory: "", title: "Continued personal task",
          summary: "Continued activity", detailedSummary: "MORE_PERSONAL_EVIDENCE", distractions: nil, appSites: nil)
        return ([historicalLeft, right], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
      })
      let continued: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
        continuedService.processBatch(extraBatch!) { continuation.resume(returning: $0) }
      }
      let nextCards = try continued.get().cardIds.compactMap { storage.fetchTimelineCard(byId: $0) }
        .sorted { $0.startTs < $1.startTs }
      XCTAssertEqual(nextCards.count, 2)
      XCTAssertEqual(nextCards.first?.startTs, base)
      XCTAssertEqual(nextCards.first?.endTs, exactSeam, "A second rewrite must not move the historical :07 seam")
      XCTAssertEqual(nextCards.last?.startTs, exactSeam)
      XCTAssertEqual(nextCards.last?.endTs, base + duration + 320)
      XCTAssertEqual(nextCards.first?.endTimestamp, nextCards.last?.startTimestamp)
    }
  }
}
