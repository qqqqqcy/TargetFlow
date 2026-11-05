import Foundation
import XCTest

@testable import Dayflow

@MainActor
final class PendingRetryStateTests: XCTestCase {
  private let base = 1_811_520_000

  private func fixture(_ body: (StorageManager, Int64, Int64, Int64, Int64) throws -> Void) throws {
    let storage = StorageManager.shared
    let image = try AIValidationFixture()
    defer { image.remove() }
    let policy = TimelineOutputPolicy()
    let values: (Int64, Int64, Int64, Int64) = try storage.timedWrite("pending retry fixture") { db in
      var batches: [Int64] = []
      var errors: [Int64] = []
      for index in 0..<2 {
        let start = base + index * 360
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts,status) VALUES (?,?,'failed')",
          arguments: [start, start + 120])
        let batch = db.lastInsertedRowID
        batches.append(batch)
        try db.execute(sql: """
          INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
          VALUES (?,?,?,?,?,?,'Processing failed','System','','')
          """, arguments: [batch, policy.formatTimestampForPrompt(start), policy.formatTimestampForPrompt(start + 120),
            start, start + 120, Date(timeIntervalSince1970: Double(start)).getDayInfoFor4AMBoundary().dayString])
        errors.append(db.lastInsertedRowID)
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,is_deleted) VALUES (?,?,0)",
          arguments: [start, image.imageURL.path])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)",
          arguments: [batch, db.lastInsertedRowID])
      }
      return (batches[0], batches[1], errors[0], errors[1])
    }
    defer { try? storage.timedWrite("pending retry cleanup") { db in
      for id in [values.0, values.1] {
        try db.execute(sql: "DELETE FROM pending_timeline_evidence WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM screenshots WHERE id IN (SELECT screenshot_id FROM batch_screenshots WHERE batch_id=?)", arguments: [id])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
    } }
    try body(storage, values.0, values.1, values.2, values.3)
  }

  func testPendingOnlySuccessRemovesOwnFailureAtomicallyAndKeepsNeighbor() throws {
    try fixture { storage, batch, neighbor, errorID, neighborErrorID in
      let source = try XCTUnwrap(storage.screenshotsForBatch(batch).first)
      let policy = TimelineOutputPolicy()
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base),
        endTime: policy.formatTimestampForPrompt(base + 60), category: "Idle", subcategory: "",
        title: "Short synthetic event", summary: "Preserved evidence", detailedSummary: "Evidence",
        distractions: nil, appSites: nil)
      let pending = PendingTimelineEvidence(id: nil, batchId: batch, startTs: base, endTs: base + 60,
        card: card, firstScreenshotId: source.id, lastScreenshotId: source.id, sourceScreenshotIds: [source.id])
      let committed = expectation(description: "pending success refreshes failure UI")
      let token = NotificationCenter.default.addObserver(forName: .timelineCardsDidCommit, object: nil, queue: nil) { _ in committed.fulfill() }
      defer { NotificationCenter.default.removeObserver(token) }
      _ = try storage.replaceTimelineCardGroups([], batchId: batch,
        keepingNewerBatchesCardsStartingAfter: nil, pendingToSave: [pending], markBatchAnalyzed: true,
        requiredScreenshotIds: [source.id])
      wait(for: [committed], timeout: 1)
      XCTAssertNil(storage.fetchTimelineCard(byId: errorID))
      XCTAssertNotNil(storage.fetchTimelineCard(byId: neighborErrorID))
      XCTAssertEqual(storage.allBatches().first { $0.id == batch }?.status, "analyzed")
      XCTAssertEqual(storage.allBatches().first { $0.id == neighbor }?.status, "failed")
      XCTAssertEqual(storage.pendingTimelineEvidence().filter { $0.batchId == batch }.count, 1)
      XCTAssertEqual(storage.screenshotsForBatch(batch).map(\.id), [source.id])
    }
  }

  func testLegacyCompletedFailureIsNotDisplayedOrRetriedButRealFailureRemains() throws {
    try fixture { storage, batch, neighbor, errorID, neighborErrorID in
      let day = Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      let card = try XCTUnwrap(storage.fetchTimelineCards(forDay: day).first { $0.recordId == errorID })
      let other = try XCTUnwrap(storage.fetchTimelineCards(forDay: day).first { $0.recordId == neighborErrorID })
      XCTAssertTrue(TimelineActivityLoader.isRetryableFailedCard(card, storageManager: storage))
      for status in ["completed", "analyzed"] {
        storage.updateBatch(batch, status: status)
        XCTAssertFalse(TimelineActivityLoader.isRetryableFailedCard(card, storageManager: storage))
        XCTAssertFalse(TimelineActivityLoader.shouldDisplay(card, storageManager: storage))
        XCTAssertTrue(TimelineActivityLoader.shouldDisplay(other, storageManager: storage))
        XCTAssertEqual(storage.allBatches().first { $0.id == neighbor }?.status, "failed")
      }
    }
  }

  func testOrdinaryCardNamedProcessingFailedStaysVisible() throws {
    try fixture { storage, batch, _, errorID, _ in
      try storage.timedWrite("ordinary card with sentinel title") { db in
        try db.execute(sql: "UPDATE timeline_cards SET category='Work' WHERE id=?", arguments: [errorID])
      }
      storage.updateBatch(batch, status: "completed")
      let day = Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      let card = try XCTUnwrap(storage.fetchTimelineCards(forDay: day).first { $0.recordId == errorID })
      XCTAssertTrue(TimelineActivityLoader.shouldDisplay(card, storageManager: storage))
      XCTAssertFalse(TimelineActivityLoader.isRetryableFailedCard(card, storageManager: storage))
    }
  }

  func testFailedCommitDoesNotClearFailureOrChangeBatchStatus() throws {
    try fixture { storage, batch, _, errorID, _ in
      XCTAssertThrowsError(try storage.replaceTimelineCardGroups([], batchId: batch,
        keepingNewerBatchesCardsStartingAfter: nil, markBatchAnalyzed: true,
        requiredScreenshotIds: [Int64.max]))
      XCTAssertNotNil(storage.fetchTimelineCard(byId: errorID))
      XCTAssertEqual(storage.allBatches().first { $0.id == batch }?.status, "failed")
      XCTAssertTrue(storage.pendingTimelineEvidence().filter { $0.batchId == batch }.isEmpty)
    }
  }
}
