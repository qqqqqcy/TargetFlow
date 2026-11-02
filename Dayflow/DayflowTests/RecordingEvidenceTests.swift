import AppKit
import Foundation
import GRDB
import XCTest

@testable import Dayflow

final class RecordingEvidenceTests: XCTestCase {
  @MainActor
  func testSyntheticPlaceholderThroughFrameStore() throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let image = try XCTUnwrap(RecordingPrivacyPlaceholder.image(width: 320, height: 180))
    let stamp = Int(Date().timeIntervalSince1970) + 3_000_000
    let id = try XCTUnwrap(FrameStore.shared.append(
      image, capturedAt: Date(timeIntervalSince1970: Double(stamp)), idleSecondsAtCapture: 121,
      isPrivacyRedacted: true))
    FrameStore.shared.finishCurrentSegment()
    defer { try? StorageManager.shared.db.write { db in try db.execute(sql: "DELETE FROM screenshots WHERE id = ?", arguments: [id]) } }
    let frame = try XCTUnwrap(StorageManager.shared.fetchScreenshotsInTimeRange(startTs: stamp, endTs: stamp).first { $0.id == id })
    XCTAssertTrue(frame.isPrivacyRedacted)
    XCTAssertEqual(frame.idleSecondsAtCapture, 121)
  }

  func testPrivacyMarkerSurvivesWriteReadAndBackup() throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let stamp = Int(Date().timeIntervalSince1970) + 2_000_000
    let redactedID = try XCTUnwrap(storage.saveScreenshot(
      segmentPath: "synthetic-segment", frameIndex: 0,
      capturedAt: Date(timeIntervalSince1970: Double(stamp)), idleSecondsAtCapture: 120,
      isPrivacyRedacted: true))
    let ordinaryID = try XCTUnwrap(storage.saveScreenshot(
      segmentPath: "synthetic-segment", frameIndex: 1,
      capturedAt: Date(timeIntervalSince1970: Double(stamp + 1)), idleSecondsAtCapture: 0))
    defer {
      try? storage.db.write { db in
        try db.execute(sql: "DELETE FROM screenshots WHERE id IN (?, ?)", arguments: [redactedID, ordinaryID])
      }
    }
    let rows = storage.fetchScreenshotsInTimeRange(startTs: stamp, endTs: stamp + 1)
    XCTAssertEqual(rows.map(\.id), [redactedID, ordinaryID])
    XCTAssertEqual(rows.map(\.isPrivacyRedacted), [true, false])
    XCTAssertEqual(rows.map(\.idleSecondsAtCapture), [120, 0])

    XCTAssertTrue(storage.fetchUnprocessedScreenshots(since: stamp).contains { $0.id == redactedID && $0.isPrivacyRedacted })
    let batchID = try XCTUnwrap(storage.saveBatchWithScreenshots(
      startTs: stamp, endTs: stamp + 1, screenshotIds: [redactedID, ordinaryID]))
    defer { try? storage.db.write { db in try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batchID]) } }
    XCTAssertEqual(storage.screenshotsForBatch(batchID).map(\.isPrivacyRedacted), [true, false])

    let backup = try DatabaseQueue()
    try storage.db.backup(to: backup)
    let persisted: [Int] = try backup.read { db in
      try Int.fetchAll(db, sql: "SELECT is_privacy_redacted FROM screenshots WHERE id IN (?, ?) ORDER BY captured_at", arguments: [redactedID, ordinaryID])
    }
    XCTAssertEqual(persisted, [1, 0])
  }

  func testOldBackupMigrationDefaultsExistingAndNewRowsToFalse() throws {
    let legacy = try DatabaseQueue()
    try legacy.write { db in
      try db.execute(sql: "CREATE TABLE screenshots (id INTEGER PRIMARY KEY, idle_seconds_at_capture INTEGER)")
      try db.execute(sql: "INSERT INTO screenshots VALUES (1, 93)")
    }
    let restored = try DatabaseQueue()
    try legacy.backup(to: restored)
    try restored.write { db in
      try StorageManager.migrateScreenshotPrivacyColumn(in: db)
      try StorageManager.migrateScreenshotPrivacyColumn(in: db)
      try db.execute(sql: "INSERT INTO screenshots(id, idle_seconds_at_capture) VALUES (2, 5)")
      let rows = try Row.fetchAll(db, sql: "SELECT is_privacy_redacted, idle_seconds_at_capture FROM screenshots ORDER BY id")
      XCTAssertEqual(rows.map { $0["is_privacy_redacted"] as Int }, [0, 0])
      XCTAssertEqual(rows.map { $0["idle_seconds_at_capture"] as Int }, [93, 5])
    }
  }

  func testLegacyScreenshotJSONAndTypedCardEvidenceRoundTrip() throws {
    let legacy = Data(#"{"id":1,"capturedAt":1,"filePath":"fixture","isDeleted":false}"#.utf8)
    XCTAssertFalse(try JSONDecoder().decode(Screenshot.self, from: legacy).isPrivacyRedacted)
    XCTAssertNil(try JSONDecoder().decode(TimelineMetadata.self, from: Data("{}".utf8)).evidenceKind)
    let storage = StorageManager.shared
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let start = Date(timeIntervalSince1970: 4_000_000_000)
    let end = start.addingTimeInterval(300)
    let batch: Int64 = try storage.db.write { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts) VALUES (?, ?)", arguments: [Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970)])
      return db.lastInsertedRowID
    }
    defer {
      try? storage.db.write { db in
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
      }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    let shell = TimelineCardShell(
      startTimestamp: formatter.string(from: start), endTimestamp: formatter.string(from: end),
      category: "", subcategory: "", title: "Privacy", summary: "", detailedSummary: "",
      distractions: nil, appSites: nil, evidenceKind: .privacyRedacted)
    let result = storage.replaceTimelineCardsInRange(from: start, to: end, with: [shell], batchId: batch, keepingNewerBatchesCardsStartingAfter: nil)
    let id = try XCTUnwrap(result.insertedIds.first)
    XCTAssertEqual(storage.fetchTimelineCard(byId: id)?.evidenceKind, .privacyRedacted)
    XCTAssertEqual(storage.fetchTimelineCardEndingLast(startingBefore: end, excludingBatchId: -1)?.evidenceKind, .privacyRedacted)
    XCTAssertEqual(storage.fetchTimelineCardsByTimeRange(from: start, to: end).first { $0.recordId == id }?.evidenceKind, .privacyRedacted)
    let (day, _, _) = start.getDayInfoFor4AMBoundary()
    XCTAssertEqual(storage.fetchTimelineCards(forDay: day).first { $0.recordId == id }?.evidenceKind, .privacyRedacted)
    let idle = storage.saveIdleBatchCard(shell, startTs: Int(start.timeIntervalSince1970), endTs: Int(end.timeIntervalSince1970), batchId: batch, extendingCardId: nil)
    let idleID = try XCTUnwrap(idle.cardId)
    XCTAssertEqual(storage.fetchTimelineCard(byId: idleID)?.evidenceKind, .privacyRedacted)
  }

  @MainActor
  func testReadingActiveSegmentDoesNotImplyARecordingPause() throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let image = try XCTUnwrap(RecordingPrivacyPlaceholder.image(width: 320, height: 180))
    let stamp = Int(Date().timeIntervalSince1970) + 3_100_000
    let firstID = try XCTUnwrap(FrameStore.shared.append(image, capturedAt: Date(timeIntervalSince1970: Double(stamp)), idleSecondsAtCapture: 0))
    let first = try XCTUnwrap(storage.fetchScreenshotsInTimeRange(startTs: stamp, endTs: stamp).first { $0.id == firstID })
    XCTAssertNotNil(FrameStore.shared.image(for: first)) // This finalizes the active segment.
    let secondID = try XCTUnwrap(FrameStore.shared.append(image, capturedAt: Date(timeIntervalSince1970: Double(stamp + 1)), idleSecondsAtCapture: 0))
    FrameStore.shared.finishCurrentSegment()
    let second = try XCTUnwrap(storage.fetchScreenshotsInTimeRange(startTs: stamp + 1, endTs: stamp + 1).first { $0.id == secondID })
    defer {
      try? storage.timedWrite("read boundary cleanup") { db in
        try db.execute(sql: "DELETE FROM screenshots WHERE id IN (?,?)", arguments: [firstID, secondID])
      }
      try? FileManager.default.removeItem(at: first.fileURL)
      try? FileManager.default.removeItem(at: second.fileURL)
    }
    XCTAssertNotEqual(first.filePath, second.filePath)
    let boundaries = TimelineCaptureBoundaries(observedSince: stamp - 1)
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: [first], next: second,
      recordedContinuity: boundaries.continuity(from: first.capturedAt, to: second.capturedAt)))
    boundaries.recordStop(at: stamp)
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: [first], next: second,
      recordedContinuity: boundaries.continuity(from: first.capturedAt, to: second.capturedAt)))
    XCTAssertEqual(TimelineCaptureBoundaries(observedSince: stamp + 1).continuity(from: stamp, to: stamp + 1), false)
    XCTAssertNil(TimelineCaptureBoundaries(observedSince: stamp + 2).continuity(from: stamp, to: stamp + 1))
  }

}
