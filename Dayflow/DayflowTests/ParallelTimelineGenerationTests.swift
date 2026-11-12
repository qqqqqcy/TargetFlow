import Foundation
import XCTest
@testable import Dayflow

@MainActor
final class ParallelTimelineGenerationTests: XCTestCase {
  private let base = Int(Calendar.current.date(from: DateComponents(year: 2028, month: 2, day: 12, hour: 12, minute: 0, second: 7))!.timeIntervalSince1970)

  func testUnrelatedProvidersOverlapAndBothCommitInReverseCompletionOrder() async throws {
    try await exercise(overlap: false, providerFails: false)
  }

  func testOldResultCannotOverwriteNewCardInsertedAfterEmptySnapshot() async throws {
    try await exercise(overlap: true, providerFails: false)
  }

  func testProviderFailureCannotWritePlaceholderOverConcurrentSuccess() async throws {
    try await exercise(overlap: true, providerFails: true)
  }

  private func exercise(overlap: Bool, providerFails: Bool) async throws {
    let fixture = try setup(overlap: overlap)
    defer { clean(fixture) }
    let entered = expectation(description: "Both provider calls entered before either was released")
    entered.expectedFulfillmentCount = 2
    let latch = ProviderLatch()
    let service = makeService { frames, _, id in
      let id = try XCTUnwrap(id)
      await latch.markEntered(id)
      entered.fulfill()
      try await latch.wait(id)
      if providerFails && id == fixture.a {
        throw NSError(domain: "SyntheticProvider", code: 1)
      }
      return self.output(frames, title: id == fixture.a ? "Retry result" : "Current result")
    }
    async let a = invoke(service, fixture.a)
    async let b = invoke(service, fixture.b)
    await fulfillment(of: [entered], timeout: 3)
    guard await latch.hasEntered([fixture.a, fixture.b]) else {
      // A serial-gate regression must fail and unwind, not deadlock waiting for
      // B while A is still deliberately held by this test.
      await latch.release(fixture.a)
      await latch.release(fixture.b)
      _ = await a
      _ = await b
      return
    }
    await latch.release(fixture.b)
    let newerResult = await b
    await latch.release(fixture.a)
    let newer = try newerResult.get()
    XCTAssertEqual(newer.cardIds.count, 1)
    let newerID = try XCTUnwrap(newer.cardIds.first)
    let older = await a
    if overlap {
      guard case .failure(let error) = older else { return XCTFail("A stale result was accepted") }
      XCTAssertEqual(error as? TimelineCardReplacementError, .timelineChanged)
      XCTAssertNotNil(StorageManager.shared.fetchTimelineCard(byId: newerID))
      let cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
        from: Date(timeIntervalSince1970: Double(base - 60)),
        to: Date(timeIntervalSince1970: Double(base + 400)))
      XCTAssertEqual(cards.map(\.title), ["Current result"])
      XCTAssertFalse(cards.contains { $0.category == "System" })
    } else {
      let old = try older.get()
      XCTAssertEqual(old.cardIds.count, 1)
      XCTAssertEqual(StorageManager.shared.fetchTimelineCard(byId: newerID)?.title, "Current result")
      XCTAssertEqual(old.cardIds.first.flatMap { StorageManager.shared.fetchTimelineCard(byId: $0) }?.title, "Retry result")
    }
  }

  func testSameBatchIsClaimedAcrossServiceInstancesBeforeModelStarts() async throws {
    let fixture = try setup(overlap: false)
    defer { clean(fixture) }
    let entered = expectation(description: "First provider entered")
    let latch = ProviderLatch()
    let service = makeService { frames, _, id in
      entered.fulfill()
      try await latch.wait(try XCTUnwrap(id))
      return self.output(frames, title: "One result")
    }
    async let first = invoke(service, fixture.a)
    await fulfillment(of: [entered], timeout: 3)
    let duplicateService = makeService { _, _, _ in
      XCTFail("A duplicate batch must not reach another provider")
      throw NSError(domain: "Duplicate", code: 1)
    }
    let duplicate = await invoke(duplicateService, fixture.a)
    await latch.release(fixture.a)
    guard case .failure(let error) = duplicate else { return XCTFail("Duplicate was not rejected") }
    XCTAssertEqual((error as NSError).code, 409)
    let original = try await first.get()
    XCTAssertEqual(original.cardIds.count, 1)
  }

  private func invoke(_ service: LLMService, _ id: Int64) async -> Result<ProcessedBatchResult, Error> {
    await withCheckedContinuation { continuation in
      service.processBatch(id) { continuation.resume(returning: $0) }
    }
  }

  private func makeService(_ generator: @escaping TimelineEvidencePolicy.Generate) -> LLMService {
    let connection = AIProviderConnection(name: "Parallel stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let selection = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: selection)])
    return LLMService(loadConfiguration: { config }, timelineGeneratorOverride: generator)
  }

  private func output(_ frames: [Screenshot], title: String) -> TimelineEvidencePolicy.Result {
    let clock = TimelineOutputPolicy()
    let start = frames.first!.capturedAt
    let end = frames.last!.capturedAt
    let card = ActivityCardData(startTime: clock.formatTimestampForPrompt(start),
      endTime: clock.formatTimestampForPrompt(end / 60 * 60 + 60), category: "Idle", subcategory: "",
      title: title, summary: "Synthetic evidence", detailedSummary: "Synthetic details", distractions: nil, appSites: nil)
    return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
  }

  private struct Fixture { let a: Int64; let b: Int64; let path: String }
  private func setup(overlap: Bool) throws -> Fixture {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let path = "parallel-timeline-\(UUID().uuidString)"
    return try StorageManager.shared.timedWrite("parallel fixture") { db in
      func batch(_ start: Int) throws -> Int64 {
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [start, start + 900])
        return db.lastInsertedRowID
      }
      let a = try batch(base)
      let b = try batch(overlap ? base : base + 7200)
      for (index, id) in [a, b].enumerated() {
        if overlap && index == 1 {
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) SELECT ?,screenshot_id FROM batch_screenshots WHERE batch_id=?", arguments: [b, a])
          continue
        }
        let start = base + index * 7200
        for offset in stride(from: 0, through: 900, by: 20) {
          try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index) VALUES (?,?,?)", arguments: [start + offset, path + "-\(index)", offset / 20])
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
        }
      }
      return Fixture(a: a, b: b, path: path)
    }
  }

  private func clean(_ fixture: Fixture) {
    try? StorageManager.shared.timedWrite("parallel cleanup") { db in
      for id in [fixture.a, fixture.b] {
        try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id=?)", arguments: [id])
        try db.execute(sql: "DELETE FROM pending_timeline_evidence WHERE batch_id=?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id=?", arguments: [id])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id=?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id=?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id=?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path IN (?,?)", arguments: [fixture.path + "-0", fixture.path + "-1"])
    }
  }
}

private actor ProviderLatch {
  private var waiters: [Int64: CheckedContinuation<Void, Error>] = [:]
  private var released = Set<Int64>()
  private var entered = Set<Int64>()
  func markEntered(_ id: Int64) { entered.insert(id) }
  func hasEntered(_ ids: [Int64]) -> Bool { Set(ids).isSubset(of: entered) }
  func wait(_ id: Int64) async throws {
    if released.contains(id) { return }
    try await withCheckedThrowingContinuation { waiters[id] = $0 }
  }
  func release(_ id: Int64) {
    released.insert(id)
    waiters.removeValue(forKey: id)?.resume()
  }
}
