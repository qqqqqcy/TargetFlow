import Foundation
import GRDB
import XCTest
@testable import Dayflow

/// Only clocks and indexes from MacBook Pro batch 306 are retained.
final class TimelineSegmentRotationTests: XCTestCase {
  private let segmentStart = 1_793_687_789
  private func frame(_ timestamp: Int, path: String, index: Int) -> Screenshot {
    Screenshot(id: Int64(timestamp), capturedAt: timestamp, filePath: path, fileSize: nil,
      idleSecondsAtCapture: 0, isDeleted: false, frameIndex: index)
  }

  func testHistoricalFiveMinuteSegmentDoesNotProveContinuity() {
    let history = stride(from: 0, through: 280, by: 20).enumerated().map {
      frame($0.element, path: "old.mp4", index: $0.offset)
    }
    let next = frame(300, path: "new.mp4", index: 0)
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: history, next: next))
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: Array(history.suffix(2)), next: next, recordedContinuity: true))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: history, next: next, recordedContinuity: false))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: history, next: frame(340, path: "new.mp4", index: 0), recordedContinuity: true))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: history, next: frame(300, path: "new.mp4", index: 1), recordedContinuity: true))
  }

  private struct Fixture { let path: String; let batch: Int64; let ids: [Int64] }

  private func fixture(endOffset: Int = 560) throws -> Fixture {
    let storage = StorageManager.shared
    let path = "rotation-replay-\(UUID().uuidString)"
    return try storage.timedWrite("rotation replay setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts,status) VALUES (?,?,'failed')", arguments: [segmentStart + 260, segmentStart + endOffset])
      let batch = db.lastInsertedRowID
      var ids: [Int64] = []
      for offset in stride(from: 0, through: endOffset, by: 20) {
        let old = offset < 300
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [segmentStart + offset, path + (old ? "-old.mp4" : "-new.mp4"), (old ? offset : offset - 300) / 20])
        if offset >= 260 {
          let id = db.lastInsertedRowID
          ids.append(id)
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, id])
        }
      }
      return Fixture(path: path, batch: batch, ids: ids)
    }
  }

  private func clean(_ fixture: Fixture, extraBatch: Int64? = nil) {
    try? StorageManager.shared.timedWrite("rotation replay cleanup") { db in
      for batch in [fixture.batch, extraBatch].compactMap({ $0 }) {
        try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [batch])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
        try db.execute(sql: "DELETE FROM pending_timeline_evidence WHERE batch_id = ?", arguments: [batch])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path IN (?,?)", arguments: [fixture.path + "-old.mp4", fixture.path + "-new.mp4"])
    }
  }

  private func service(beforeCommit: (() -> Void)? = nil, count: @escaping () -> Void = {}) -> LLMService {
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    return LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, context, _ in
      count()
      let policy = TimelineOutputPolicy()
      let first = try XCTUnwrap(frames.first).capturedAt
      let last = try XCTUnwrap(frames.last).capturedAt
      let card = ActivityCardData(startTime: context.existingCards.first?.startTime ?? policy.formatTimestampForPrompt(first),
        endTime: policy.formatTimestampForPrompt(last / 60 * 60 + 60), category: "Idle", subcategory: "",
        title: "Synthetic connection setup", summary: "Synthetic event", detailedSummary: "Synthetic evidence",
        distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    }, beforeTimelineCommit: beforeCommit)
  }

  private func process(_ batch: Int64, service: LLMService) async -> Result<ProcessedBatchResult, Error> {
    await withCheckedContinuation { continuation in
      service.processBatch(batch) { continuation.resume(returning: $0) }
    }
  }

  @MainActor
  func testUnknownRotationProducesIsolatedPendingRunsAndOnlyLatestRunContinues() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = oldArguments
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    let fixture = try fixture()
    var nextBatch: Int64?
    defer { clean(fixture, extraBatch: nextBatch) }
    var calls = 0
    let service = service(count: { calls += 1 })
    for _ in 0..<2 {
      let result = try await process(fixture.batch, service: service).get()
      XCTAssertTrue(result.cardIds.isEmpty)
      let pending = storage.pendingTimelineEvidence().filter { $0.batchId == fixture.batch }
      XCTAssertEqual(pending.count, 2, "Retry must replace its own runs, not duplicate or merge them")
      let a = try XCTUnwrap(pending.first { $0.startTs == segmentStart + 260 })
      let b = try XCTUnwrap(pending.first { $0.startTs == segmentStart + 300 })
      XCTAssertEqual(a.endTs, segmentStart + 280)
      XCTAssertEqual(b.endTs, segmentStart + 560)
      XCTAssertEqual(Set(a.sourceScreenshotIds), Set(fixture.ids.prefix(2)))
      XCTAssertEqual(Set(b.sourceScreenshotIds), Set(fixture.ids.dropFirst(2)))
      XCTAssertTrue(Set(a.sourceScreenshotIds).isDisjoint(with: b.sourceScreenshotIds))
    }
    XCTAssertEqual(calls, 4)
    XCTAssertEqual(storage.allBatches().first { $0.0 == fixture.batch }?.3, "analyzed")
    nextBatch = try storage.timedWrite("rotation continuation setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [segmentStart + 580, segmentStart + 600])
      let batch = db.lastInsertedRowID
      for offset in [580, 600] {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index) VALUES (?,?,?)", arguments: [segmentStart + offset, fixture.path + "-new.mp4", (offset - 300) / 20])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
      }
      return batch
    }
    let result = try await process(try XCTUnwrap(nextBatch), service: service).get()
    XCTAssertEqual(result.cardIds.count, 1)
    let saved = try XCTUnwrap(result.cardIds.first.flatMap { storage.fetchTimelineCard(byId: $0) })
    XCTAssertEqual(saved.startTs, segmentStart + 300)
    XCTAssertEqual(saved.endTs, segmentStart + 600)
    let remaining = storage.pendingTimelineEvidence().filter { $0.batchId == fixture.batch }
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(remaining.first?.startTs, segmentStart + 260)
    XCTAssertEqual(Set(remaining.first!.sourceScreenshotIds), Set(fixture.ids.prefix(2)))
  }

  @MainActor
  func testOverlappingMinuteWindowsDoNotMixOrDeleteOtherPendingRun() async throws {
    let fixture = try fixture(endOffset: 320)
    defer { clean(fixture) }
    let service = service()
    for _ in 0..<2 {
      let result = try await process(fixture.batch, service: service).get()
      XCTAssertTrue(result.cardIds.isEmpty)
      let pending = StorageManager.shared.pendingTimelineEvidence().filter { $0.batchId == fixture.batch }
      XCTAssertEqual(pending.count, 2)
      let a = try XCTUnwrap(pending.first { $0.startTs == segmentStart + 260 })
      let b = try XCTUnwrap(pending.first { $0.startTs == segmentStart + 300 })
      XCTAssertEqual(a.endTs, segmentStart + 280)
      XCTAssertEqual(b.endTs, segmentStart + 320)
      XCTAssertEqual(Set(a.sourceScreenshotIds), Set(fixture.ids.prefix(2)))
      XCTAssertEqual(Set(b.sourceScreenshotIds), Set(fixture.ids.suffix(2)))
    }
  }

  @MainActor
  func testRetryStabilizesBriefSwitchesWithoutLeavingStaleWholeRun() async throws {
    let defaults = AppStoragePaths.defaults
    let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = prior
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
    let fixture = try fixture()
    defer { clean(fixture) }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    var split = false
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, _, _ in
      let policy = TimelineOutputPolicy()
      let first = try XCTUnwrap(frames.first).capturedAt
      let last = try XCTUnwrap(frames.last).capturedAt
      func card(_ start: Int, _ end: Int, _ category: String) -> ActivityCardData {
        ActivityCardData(startTime: policy.formatTimestampForPrompt(start), endTime: policy.formatTimestampForPrompt(end),
          category: category, subcategory: "", title: "Synthetic revised event", summary: "Synthetic", detailedSummary: "Synthetic",
          distractions: nil, appSites: nil)
      }
      let end = last / 60 * 60 + 60
      let cards: [ActivityCardData]
      if split && frames.count > 2 {
        let boundary = first / 60 * 60 + 180
        cards = [card(first, boundary, "Idle"), card(boundary, end, "Work")]
      } else { cards = [card(first, end, "Idle")] }
      return (cards, [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    _ = try await process(fixture.batch, service: service).get()
    let old = try XCTUnwrap(StorageManager.shared.pendingTimelineEvidence().first {
      $0.batchId == fixture.batch && $0.startTs == segmentStart + 300
    })
    split = true
    _ = try await process(fixture.batch, service: service).get()
    let pending = StorageManager.shared.pendingTimelineEvidence().filter { $0.batchId == fixture.batch }
    XCTAssertEqual(pending.count, 2, "Run A stays separate; short switches in run B form one stable pending event")
    XCTAssertFalse(pending.contains { $0.id == old.id })
    XCTAssertEqual(pending.filter { $0.startTs >= segmentStart + 300 }.count, 1)
    XCTAssertEqual(pending.filter { $0.startTs == segmentStart + 260 }.count, 1)
  }

  @MainActor
  func testSourceDeletionRollsBackAllRuns() async throws {
    let fixture = try fixture()
    defer { clean(fixture) }
    let service = service(beforeCommit: {
      try? StorageManager.shared.timedWrite("remove rotation source") { db in
        try db.execute(sql: "UPDATE screenshots SET is_deleted = 1 WHERE id = ?", arguments: [fixture.ids[5]])
      }
    })
    let result = await process(fixture.batch, service: service)
    guard case .failure(let error) = result else { return XCTFail("Deleted input must abort all run writes") }
    XCTAssertEqual(error as? TimelineCardReplacementError, .sourceEvidenceChanged)
    XCTAssertTrue(StorageManager.shared.pendingTimelineEvidence().filter { $0.batchId == fixture.batch }.isEmpty)
  }
}
