import Foundation
import GRDB
import XCTest
@testable import Dayflow

@MainActor
final class TimelineRewriteSnapshotTests: XCTestCase {
  private let storage = StorageManager.shared
  private let base = 1_950_000_000
  private var batch: Int64 = 0
  private var card: Int64 = 0
  private var pending: Int64 = 0
  private var sources: [Int64] = []

  override func setUpWithError() throws {
    try super.setUpWithError()
    try storage.timedWrite("snapshot fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts,status) VALUES (?,?,'failed')",
        arguments: [base, base + 600])
      batch = db.lastInsertedRowID
      for offset in [0, 60, 120] {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path) VALUES (?,'snapshot-test')", arguments: [base + offset])
        sources.append(db.lastInsertedRowID)
      }
      card = try insertCard(in: db, start: base, end: base + 600)
      try db.execute(sql: """
        INSERT INTO pending_timeline_evidence(batch_id,start_ts,end_ts,card_json,first_screenshot_id,last_screenshot_id)
        VALUES (?,?,?,'{}',?,?)
        """, arguments: [batch, base, base + 60, sources[0], sources[1]])
      pending = db.lastInsertedRowID
      for id in sources.prefix(2).reversed() {
        try db.execute(sql: "INSERT INTO pending_timeline_sources VALUES (?,?)", arguments: [pending, id])
      }
    }
  }

  override func tearDownWithError() throws {
    try storage.timedWrite("snapshot cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ? OR id = ?", arguments: [batch, card])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
      for id in sources { try db.execute(sql: "DELETE FROM screenshots WHERE id = ?", arguments: [id]) }
    }
    sources = []
    try super.tearDownWithError()
  }

  private func insertCard(in db: Database, start: Int, end: Int) throws -> Int64 {
    try db.execute(sql: """
      INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
      VALUES (?,'9:00 AM','9:10 AM',?,?,'2031-10-17','Original','Work','Summary','Detail')
      """, arguments: [batch, start, end])
    return db.lastInsertedRowID
  }

  private func snapshot() throws -> TimelineRewriteSnapshot {
    try storage.captureTimelineRewriteSnapshot(from: base, to: base + 600)
  }

  private func commit(_ expected: TimelineRewriteSnapshot?, groups: [TimelineCardReplacementGroup] = [],
    requiredSources: [Int64] = []) throws {
    _ = try storage.replaceTimelineCardGroups(groups, batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil, pendingToDelete: [pending],
      markBatchAnalyzed: true, replacementObservations: [], requiredScreenshotIds: requiredSources,
      expectedTimeline: expected)
  }

  /// total_changes counts even rolled-back writes, proving the guard precedes mutations.
  private func assertRejectedBeforeWrites(_ expected: TimelineRewriteSnapshot,
    error: TimelineCardReplacementError = .timelineChanged, requiredSources: [Int64] = [],
    file: StaticString = #filePath, line: UInt = #line) throws {
    let current = try snapshot()
    let writes = try storage.timedWrite("snapshot writer change count") { try Int.fetchOne($0, sql: "SELECT total_changes()") }
    XCTAssertThrowsError(try commit(expected, groups: [replacementGroup()], requiredSources: requiredSources), file: file, line: line) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, error, file: file, line: line)
    }
    let after = try storage.timedWrite("snapshot writer change count") { try Int.fetchOne($0, sql: "SELECT total_changes()") }
    XCTAssertEqual(writes, after, file: file, line: line)
    XCTAssertEqual(try snapshot(), current, file: file, line: line)
    XCTAssertEqual(storage.allBatches().first { $0.id == batch }?.status, "failed", file: file, line: line)
  }

  private func replacementGroup(from: Int? = nil, to: Int? = nil) -> TimelineCardReplacementGroup {
    let start = from ?? base
    let end = to ?? base + 600
    let shell = TimelineCardShell(startTimestamp: "9:00 AM", endTimestamp: "9:10 AM", category: "Work",
      subcategory: "", title: "Replacement", summary: "", detailedSummary: "", distractions: nil, appSites: nil,
      exactStartTs: start, exactEndTs: end)
    return TimelineCardReplacementGroup(from: Date(timeIntervalSince1970: Double(start)),
      to: Date(timeIntervalSince1970: Double(end)), cards: [shell])
  }

  func testRewriteOutsideCapturedBaselineIsRejectedBeforeWrites() throws {
    let expected = try snapshot()
    XCTAssertThrowsError(try commit(expected, groups: [replacementGroup(from: base - 60)])) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, .timelineChanged)
    }
    XCTAssertEqual(try snapshot(), expected)
    XCTAssertNotNil(storage.fetchTimelineCard(byId: card))
  }

  func testConsumedCardOutsideBaselineCannotBeGrandfathered() throws {
    let outside = try storage.timedWrite("unobserved consumed card") { db in
      try insertCard(in: db, start: base + 1200, end: base + 1500)
    }
    let expected = try snapshot()
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups(
      [replacementGroup()], batchId: batch, keepingNewerBatchesCardsStartingAfter: nil,
      requiredCardIds: [outside], expectedTimeline: expected)) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, .timelineChanged)
    }
    XCTAssertEqual(try snapshot(), expected)
    XCTAssertNotNil(storage.fetchTimelineCard(byId: outside))
  }

  func testSameIDSemanticCardEditsRejectCommit() throws {
    for assignment in ["start = '8:59 AM'", "end = '9:11 AM'", "start_ts = start_ts + 1",
      "end_ts = end_ts - 1", "day = '2031-10-18'", "title = 'Edited'", "summary = NULL",
      "category = 'Idle'", "subcategory = 'Changed'", "detailed_summary = 'Changed'", "metadata = '{}'", "batch_id = NULL"] {
      let expected = try snapshot()
      try storage.timedWrite("semantic card edit") { db in
        try db.execute(sql: "UPDATE timeline_cards SET \(assignment) WHERE id = ?", arguments: [card])
      }
      XCTAssertFalse(storage.timelineRewriteMatches(expected), assignment)
      try assertRejectedBeforeWrites(expected)
    }
    // Restore ownership for fixture cleanup after testing batch_id.
    try storage.timedWrite("restore fixture owner") { db in
      try db.execute(sql: "UPDATE timeline_cards SET batch_id = ? WHERE id = ?", arguments: [batch, card])
    }
  }

  func testOverlappingInsertAndActiveCardDeletionRejectCommit() throws {
    for range in [(base - 60, base + 1), (base + 120, base + 120), (base, base)] {
      let expected = try snapshot()
      try storage.timedWrite("overlapping insert") { db in
        _ = try insertCard(in: db, start: range.0, end: range.1)
      }
      try assertRejectedBeforeWrites(expected)
    }
    let expected = try snapshot()
    try storage.timedWrite("card deletion") { db in
      try db.execute(sql: "UPDATE timeline_cards SET is_deleted = 1 WHERE id = ?", arguments: [card])
    }
    try assertRejectedBeforeWrites(expected)
  }

  func testPendingSemanticEditsAndSourceChangesRejectCommit() throws {
    for assignment in ["card_json = '{\"title\":\"changed\"}'", "start_ts = start_ts + 1",
      "end_ts = end_ts + 1", "first_screenshot_id = \(sources[2])", "last_screenshot_id = \(sources[2])"] {
      let expected = try snapshot()
      try storage.timedWrite("pending rewrite") { db in
        try db.execute(sql: "UPDATE pending_timeline_evidence SET \(assignment) WHERE id = ?", arguments: [pending])
      }
      try assertRejectedBeforeWrites(expected)
    }
    var expected = try snapshot()
    try storage.timedWrite("pending new source") { db in
      try db.execute(sql: "INSERT INTO pending_timeline_sources VALUES (?,?)", arguments: [pending, sources[2]])
    }
    try assertRejectedBeforeWrites(expected)
    expected = try snapshot()
    try storage.timedWrite("pending removed source") { db in
      try db.execute(sql: "DELETE FROM pending_timeline_sources WHERE pending_id = ? AND screenshot_id = ?",
        arguments: [pending, sources[0]])
    }
    try assertRejectedBeforeWrites(expected)
  }

  func testPendingZeroLengthInsertRejectsCommit() throws {
    let expected = try snapshot()
    try storage.timedWrite("pending zero length insert") { db in
      try db.execute(sql: """
        INSERT INTO pending_timeline_evidence(batch_id,start_ts,end_ts,card_json,first_screenshot_id,last_screenshot_id)
        VALUES (?,?,?,'{}',?,?)
        """, arguments: [batch, base + 300, base + 300, sources[0], sources[1]])
    }
    try assertRejectedBeforeWrites(expected)
  }

  func testSourceDeletionStillReportsSourceEvidenceChanged() throws {
    let expected = try snapshot()
    try storage.timedWrite("delete required source") { db in
      try db.execute(sql: "UPDATE screenshots SET is_deleted = 1 WHERE id = ?", arguments: [sources[0]])
    }
    try assertRejectedBeforeWrites(expected, error: .sourceEvidenceChanged, requiredSources: [sources[0]])
  }

  func testDisjointChangesAndSourceOrderingPermitCommit() throws {
    let expected = try snapshot()
    try storage.timedWrite("disjoint changes") { db in
      _ = try insertCard(in: db, start: base + 600, end: base + 660)
      _ = try insertCard(in: db, start: base - 60, end: base)
      try db.execute(sql: """
        INSERT INTO pending_timeline_evidence(batch_id,start_ts,end_ts,card_json,first_screenshot_id,last_screenshot_id)
        VALUES (?,?,?,'{}',?,?)
        """, arguments: [batch, base + 600, base + 600, sources[0], sources[1]])
      try db.execute(sql: "DELETE FROM pending_timeline_sources WHERE pending_id = ?", arguments: [pending])
      for id in sources.prefix(2) {
        try db.execute(sql: "INSERT INTO pending_timeline_sources VALUES (?,?)", arguments: [pending, id])
      }
      try db.execute(sql: "UPDATE timeline_cards SET video_summary_url = 'rendered.mp4' WHERE id = ?", arguments: [card])
    }
    XCTAssertEqual(try snapshot(), expected)
    XCTAssertTrue(storage.timelineRewriteMatches(expected))
    let shell = TimelineCardShell(startTimestamp: "9:00 AM", endTimestamp: "9:10 AM", category: "Work",
      subcategory: "", title: "Replacement", summary: "", detailedSummary: "", distractions: nil, appSites: nil,
      exactStartTs: base, exactEndTs: base + 600)
    try commit(expected, groups: [TimelineCardReplacementGroup(
      from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 600)), cards: [shell])])
    XCTAssertEqual(storage.allBatches().first { $0.id == batch }?.status, "analyzed")
    XCTAssertNil(storage.fetchTimelineCard(byId: card))
  }

  func testUnrelatedEditInsideLookbackDoesNotConflictWithActualRewrite() throws {
    let neighbor = try storage.timedWrite("lookback neighbor") { db in
      try insertCard(in: db, start: base + 1200, end: base + 1500)
    }
    let expected = try storage.captureTimelineRewriteSnapshot(from: base - 600, to: base + 1800)
    try storage.updateTimelineCard(cardId: neighbor, title: "Unrelated edit", category: nil)
    XCTAssertFalse(storage.timelineRewriteMatches(expected), "Failure-path checks remain conservative")
    try commit(expected, groups: [replacementGroup()])
    XCTAssertEqual(storage.fetchTimelineCard(byId: neighbor)?.title, "Unrelated edit")
  }

  func testDisconnectedGroupsDoNotConsumeTheGapBetweenThem() throws {
    let gap = try storage.timedWrite("disconnected rewrite fixture") { db in
      _ = try insertCard(in: db, start: base + 1200, end: base + 1500)
      return try insertCard(in: db, start: base + 800, end: base + 900)
    }
    let expected = try storage.captureTimelineRewriteSnapshot(from: base, to: base + 1800)
    try storage.updateTimelineCard(cardId: gap, title: "Gap edit", category: nil)
    try commit(expected, groups: [replacementGroup(), replacementGroup(from: base + 1200, to: base + 1500)])
    XCTAssertEqual(storage.fetchTimelineCard(byId: gap)?.title, "Gap edit")
  }

  func testBatchStatusOnlyCommitChecksRelatedRows() throws {
    let expected = try snapshot()
    try storage.updateTimelineCard(cardId: card, title: "Batch context changed", category: nil)
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups([], batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil, markBatchAnalyzed: true, expectedTimeline: expected)) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, .timelineChanged)
    }
    XCTAssertEqual(storage.allBatches().first { $0.id == batch }?.status, "failed")
  }

  func testExplicitConsumedCardOutsideReplacementStillConflicts() throws {
    let neighbor = try storage.timedWrite("consumed neighbor") { db in
      try insertCard(in: db, start: base + 1200, end: base + 1500)
    }
    let expected = try storage.captureTimelineRewriteSnapshot(from: base, to: base + 1800)
    try storage.updateTimelineCard(cardId: neighbor, title: "Consumed edit", category: nil)
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups([replacementGroup()], batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil, requiredCardIds: [neighbor], expectedTimeline: expected)) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, .timelineChanged)
    }
    XCTAssertNotNil(storage.fetchTimelineCard(byId: card))
  }

  func testPendingSaveUsesItsRangeAndIgnoresUnrelatedLookback() throws {
    let neighbor = try storage.timedWrite("pending save neighbor") { db in
      try insertCard(in: db, start: base + 1200, end: base + 1500)
    }
    let expected = try storage.captureTimelineRewriteSnapshot(from: base, to: base + 1800)
    let data = ActivityCardData(startTime: "9:00 AM", endTime: "9:01 AM", category: "Work", subcategory: "",
      title: "Pending", summary: "", detailedSummary: "", distractions: nil, appSites: nil)
    let save = PendingTimelineEvidence(id: nil, batchId: batch, startTs: base, endTs: base + 60,
      card: data, firstScreenshotId: sources[0], lastScreenshotId: sources[1])
    try storage.updateTimelineCard(cardId: card, title: "Affected edit", category: nil)
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups([], batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil, pendingToSave: [save], expectedTimeline: expected)) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, .timelineChanged)
    }
    let refreshed = try storage.captureTimelineRewriteSnapshot(from: base, to: base + 1800)
    try storage.updateTimelineCard(cardId: neighbor, title: "Unrelated edit", category: nil)
    _ = try storage.replaceTimelineCardGroups([], batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil, pendingToSave: [save], expectedTimeline: refreshed)
  }

  func testPendingDeletionConsumesItsOriginalRange() throws {
    let expected = try snapshot()
    try storage.updateTimelineCard(cardId: card, title: "Overlaps deleted pending", category: nil)
    XCTAssertThrowsError(try commit(expected)) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, .timelineChanged)
    }
  }

  func testBatchPlaceholderOutsideGroupsIsComparedBeforeClearing() throws {
    let placeholder = try storage.timedWrite("outside placeholder") { db in
      let id = try insertCard(in: db, start: base + 1200, end: base + 1500)
      try db.execute(sql: "UPDATE timeline_cards SET category = 'System', title = 'Processing failed' WHERE id = ?", arguments: [id])
      return id
    }
    let expected = try storage.captureTimelineRewriteSnapshot(from: base, to: base + 1800)
    try storage.timedWrite("placeholder semantic edit") { db in
      try db.execute(sql: "UPDATE timeline_cards SET summary = 'Changed failure' WHERE id = ?", arguments: [placeholder])
    }
    XCTAssertThrowsError(try commit(expected, groups: [replacementGroup()])) {
      XCTAssertEqual($0 as? TimelineCardReplacementError, .timelineChanged)
    }
    XCTAssertNotNil(storage.fetchTimelineCard(byId: placeholder))
    XCTAssertNotNil(storage.fetchTimelineCard(byId: card))
  }

  func testCallerWithoutSnapshotKeepsExistingBehavior() throws {
    try storage.updateTimelineCard(cardId: card, title: "Edited", category: nil)
    try commit(nil)
    XCTAssertEqual(storage.allBatches().first { $0.id == batch }?.status, "analyzed")
  }
}
