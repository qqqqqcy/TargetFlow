import Foundation
import XCTest
@testable import Dayflow

final class SameLabelSingleEventTests: XCTestCase {
  private var previousArguments: [String: Any] = [:]

  override func setUp() {
    super.setUp()
    previousArguments = AppStoragePaths.defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = previousArguments
    arguments[AnalysisPreferences.intervalKey] = 60
    AppStoragePaths.defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
  }

  override func tearDown() {
    AppStoragePaths.defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
    super.tearDown()
  }
  private func card(_ start: String, _ end: String, _ title: String, category: String = "Work", kind: ActivityEvidenceKind? = .visible) -> ActivityCardData {
    ActivityCardData(startTime: start, endTime: end, category: category, subcategory: "", title: title,
      summary: "Summary \(title)", detailedSummary: "Detail \(title)", distractions: nil, appSites: nil, evidenceKind: kind)
  }

  func testMergesFactsAndKeepsDifferentLabelsAndGaps() throws {
    let items = [card("9:00 AM", "9:05 AM", "A"), card("9:05 AM", "9:10 AM", "B"),
      card("9:10 AM", "9:15 AM", "C", category: "Idle"), card("9:16 AM", "9:20 AM", "D", category: "Idle")]
    XCTAssertThrowsError(try TimelineEvidencePolicy.mergeConsecutiveSameLabel(items, nearest: Int(Date().timeIntervalSince1970)))
  }

  func testLegacyRedactionRequiresOrdinaryRewriteWhileDurationAndInactivityRemainBoundaries() throws {
    let anchor = Int(Date().timeIntervalSince1970)
    let items = [card("10:00 AM", "10:01 AM", "C"),
      card("10:01 AM", "10:02 AM", "Legacy redacted", kind: .privacyRedacted)]
    XCTAssertThrowsError(try TimelineEvidencePolicy.mergeConsecutiveSameLabel(items, nearest: anchor))
    let inactive = [items[0], card("10:01 AM", "10:02 AM", "No input", kind: .inputInactive)]
    XCTAssertEqual(try TimelineEvidencePolicy.mergeConsecutiveSameLabel(inactive, nearest: anchor).count, 2)
    let overLimit = [card("9:00 AM", "10:00 AM", "A"), card("10:00 AM", "10:01 AM", "B")]
    XCTAssertEqual(try TimelineEvidencePolicy.mergeConsecutiveSameLabel(overLimit, nearest: Int(Date().timeIntervalSince1970)).count, 2)
  }
  func testConnectedBatchRewritesOneStoredRecordWithAllFacts() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let base = 1_800_000_000
    let policy = TimelineOutputPolicy()
    let storage = StorageManager.shared
    let batch: Int64 = try storage.timedWrite("single event fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 120])
      return db.lastInsertedRowID
    }
    defer { try? storage.timedWrite("single event cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let old = ActivityCardData(startTime: policy.formatTimestampForPrompt(base - 120),
      endTime: policy.formatTimestampForPrompt(base), category: "Idle", subcategory: "",
      title: "Earlier subject", summary: "Earlier summary", detailedSummary: "Earlier evidence",
      distractions: nil, appSites: AppSites(primary: "old.example", secondary: nil), evidenceKind: .visible)
    let oldID: Int64 = try storage.timedWrite("single event old record") { db in
      try db.execute(sql: """
        INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,summary,category,subcategory,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [old.startTime, old.endTime, base - 120, base,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          old.title, old.summary, old.category, old.subcategory, old.detailedSummary])
      return db.lastInsertedRowID
    }
    defer { try? storage.timedWrite("single event old cleanup") { db in
      try db.execute(sql: "DELETE FROM target_assessments WHERE card_id = ?", arguments: [oldID])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ?", arguments: [oldID])
    } }
    let oldStored = try XCTUnwrap(storage.fetchTimelineCard(byId: oldID))
    let assessment = TargetAssessment(cardID: oldID, targetID: UUID(), targetText: "Synthetic goal",
      cardTitle: oldStored.title, fingerprint: TargetStore.fingerprint(oldStored),
      startTime: Date(timeIntervalSince1970: Double(oldStored.startTs)),
      endTime: Date(timeIntervalSince1970: Double(oldStored.endTs)),
      alignment: .focused, reason: "Earlier only", reminder: "")
    XCTAssertTrue(try storage.saveTargetAssessment(assessment, card: oldStored))
    let current = ActivityCardData(startTime: policy.formatTimestampForPrompt(base),
      endTime: policy.formatTimestampForPrompt(base + 120), category: "Idle", subcategory: "",
      title: "Later subject", summary: "Later summary", detailedSummary: "Later evidence",
      distractions: nil, appSites: AppSites(primary: "new.example", secondary: nil), evidenceKind: .visible)
    let context = ActivityGenerationContext(batchObservations: [], existingCards: [old],
      currentTime: Date(timeIntervalSince1970: Double(base + 120)), categories: [], hasPreviousCardWithinFiveMinutes: true,
      hasContinuousCaptureBeforeBatch: true)
    let frames = [0, 60].map { offset in Screenshot(id: Int64(offset), capturedAt: base + offset,
      filePath: "synthetic", fileSize: nil, idleSecondsAtCapture: 0, isDeleted: false, isPrivacyRedacted: offset == 0) }
    var requests = 0
    let result = try await TimelineEvidencePolicy.generate(screenshots: frames, context: context, batchId: batch) { shots, context, _ in
      requests += 1
      XCTAssertEqual(shots.map(\.id), frames.map(\.id))
      XCTAssertTrue(shots[0].isPrivacyRedacted)
      XCTAssertEqual(context.existingCards.count, 1)
      let rewritten = ActivityCardData(startTime: old.startTime, endTime: current.endTime,
        category: "Idle", subcategory: "", title: "A natural combined title",
        summary: "A coherent account of both subjects", detailedSummary: "Later evidence new.example",
        distractions: nil, appSites: current.appSites, evidenceKind: .visible)
      return ([rewritten], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    }
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(result.cards.count, 1)
    let merged = try XCTUnwrap(result.cards.first)
    XCTAssertEqual(merged.title, "A natural combined title")
    XCTAssertEqual(merged.summary, "A coherent account of both subjects")
    for value in ["Earlier subject", "Earlier evidence", "Later evidence", "old.example", "new.example"] {
      XCTAssertTrue((merged.title + merged.summary + merged.detailedSummary).contains(value), value)
    }
    let range = try XCTUnwrap(TimelineEvidencePolicy.replacementGroups(result.cards, nearest: base).first)
    let shell = TimelineCardShell(startTimestamp: merged.startTime, endTimestamp: merged.endTime,
      category: merged.category, subcategory: merged.subcategory, title: merged.title, summary: merged.summary,
      detailedSummary: merged.detailedSummary, distractions: merged.distractions, appSites: merged.appSites,
      evidenceKind: merged.evidenceKind)
    let persisted = try storage.replaceTimelineCardGroups([TimelineCardReplacementGroup(
      from: Date(timeIntervalSince1970: Double(range.range.lowerBound)),
      to: Date(timeIntervalSince1970: Double(range.range.upperBound)), cards: [shell])],
      batchId: batch, keepingNewerBatchesCardsStartingAfter: nil)
    XCTAssertEqual(persisted.insertedIds.count, 1)
    XCTAssertNil(storage.fetchTimelineCard(byId: oldID))
    let saved = try XCTUnwrap(storage.fetchTimelineCard(byId: persisted.insertedIds[0]))
    XCTAssertTrue(saved.detailedSummary.contains("Earlier evidence"))
    XCTAssertTrue(saved.detailedSummary.contains("Later evidence"))
    XCTAssertEqual(saved.startTs, base - 120)
    XCTAssertEqual(saved.endTs, base + 120)
    XCTAssertNotEqual(saved.id, oldID)
    XCTAssertFalse(try storage.fetchTargetAssessments().contains { $0.cardID == saved.id })
    XCTAssertNotEqual(TargetStore.fingerprint(saved), TargetStore.fingerprint(oldStored))
    let screenshotIDs = try [base - 60, base + 60, base + 120].map { stamp in
      try XCTUnwrap(storage.saveScreenshot(segmentPath: "synthetic-single-event", frameIndex: 0,
        capturedAt: Date(timeIntervalSince1970: Double(stamp)), idleSecondsAtCapture: 0,
        isPrivacyRedacted: stamp == base + 60))
    }
    defer { try? storage.timedWrite("single event screenshot cleanup") { db in
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-single-event'")
    } }
    let screenshots = try await ActivityCardTimelapseGenerator(storage: storage).screenshots(forCardId: saved.id)
    let selected = Set(screenshots.compactMap(\.id))
    XCTAssertTrue(selected.contains(screenshotIDs[0]))
    XCTAssertTrue(selected.contains(screenshotIDs[1]))
    XCTAssertFalse(selected.contains(screenshotIDs[2]))
  }

  func testFourAMAndIdleBoundaries() throws {
    let anchor = Int(Date().timeIntervalSince1970)
    let acrossDay = try TimelineEvidencePolicy.mergeConsecutiveSameLabel([
      card("3:58 AM", "4:00 AM", "A", category: "Idle"),
      card("4:00 AM", "4:02 AM", "B", category: "Idle")], nearest: anchor)
    XCTAssertEqual(acrossDay.count, 2)
    XCTAssertThrowsError(try TimelineEvidencePolicy.mergeConsecutiveSameLabel([
      card("9:00 AM", "9:02 AM", "A", category: "Idle"),
      card("9:02 AM", "9:04 AM", "B", category: "Idle")], nearest: anchor))
  }

  func testSecondPrecisionGapCannotRewritePreviousHistory() async throws {
    let base = 1_800_000_000
    let storage = StorageManager.shared
    let policy = TimelineOutputPolicy()
    let old = ActivityCardData(startTime: policy.formatTimestampForPrompt(base - 120),
      endTime: policy.formatTimestampForPrompt(base), category: "Idle", subcategory: "",
      title: "Old", summary: "Old", detailedSummary: "Old evidence", distractions: nil, appSites: nil)
    let oldID: Int64 = try storage.timedWrite("second gap setup") { db in
      try db.execute(sql: """
        INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?)
        """, arguments: [old.startTime, old.endTime, base - 120, base + 1,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          old.title, old.category, old.summary, old.detailedSummary])
      return db.lastInsertedRowID
    }
    defer { try? storage.timedWrite("second gap cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ?", arguments: [oldID])
    } }
    let read = try XCTUnwrap(storage.fetchTimelineCard(byId: oldID))
    XCTAssertEqual(read.endTs, base + 1)
    let context = ActivityGenerationContext(batchObservations: [], existingCards: [old],
      currentTime: Date(timeIntervalSince1970: Double(base + 120)), categories: [], hasPreviousCardWithinFiveMinutes: true)
    let frames = [2, 62].map { offset in Screenshot(id: Int64(offset), capturedAt: base + offset,
      filePath: "synthetic", fileSize: nil, idleSecondsAtCapture: 0, isDeleted: false, isPrivacyRedacted: false) }
    let next = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + 120),
      category: "Idle", subcategory: "", title: "New", summary: "New", detailedSummary: "New evidence", distractions: nil, appSites: nil)
    let result = try await TimelineEvidencePolicy.generate(screenshots: frames, context: context, batchId: 999999) { _, context, _ in
      XCTAssertTrue(context.existingCards.isEmpty)
      return ([next], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    }
    let item = try XCTUnwrap(result.cards.first)
    let shell = TimelineCardShell(startTimestamp: item.startTime, endTimestamp: item.endTime, category: item.category,
      subcategory: item.subcategory, title: item.title, summary: item.summary,
      detailedSummary: item.detailedSummary, distractions: nil, appSites: nil, evidenceKind: item.evidenceKind)
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups([TimelineCardReplacementGroup(
      from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 120)), cards: [shell])],
      batchId: 999999, keepingNewerBatchesCardsStartingAfter: nil))
    XCTAssertNotNil(storage.fetchTimelineCard(byId: oldID))
  }

  func testProcessBatchSaveFailureDoesNotWriteFailureOverHistory() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let base = 1_800_100_020
    let policy = TimelineOutputPolicy()
    let (batch, oldID): (Int64, Int64) = try storage.timedWrite("failure path fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 120])
      let batch = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?)
        """, arguments: [policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 60), base, base + 60,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          "History retained", "Idle", "History", "History evidence"])
      let oldID = db.lastInsertedRowID
      for (index, offset) in [0, 60].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, "synthetic-save-failure", index])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
      }
      try db.execute(sql: """
        CREATE TRIGGER synthetic_single_event_failure BEFORE INSERT ON timeline_cards
        WHEN NEW.title = 'Synthetic write failure'
        BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END
        """)
      return (batch, oldID)
    }
    defer { try? storage.timedWrite("failure path cleanup") { db in
      try db.execute(sql: "DROP TRIGGER IF EXISTS synthetic_single_event_failure")
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-save-failure'")
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ? OR batch_id = ?", arguments: [oldID, batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, _, _ in
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + 120),
        category: "Idle", subcategory: "", title: "Synthetic write failure", summary: "Test", detailedSummary: "Test", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    if case .success = result { XCTFail("Expected the insert trigger to fail") }
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldID)?.title, "History retained")
    let cards = storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 120)))
    XCTAssertFalse(cards.contains { $0.batchId == batch && $0.title == "Processing failed" })
  }

  func testRepeatedMultipleCardsPreserveSameBatchHistory() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let base = 1_800_110_040
    let policy = TimelineOutputPolicy()
    let (batch, oldID): (Int64, Int64) = try storage.timedWrite("natural retry failure fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 120])
      let batch = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [batch, policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 120), base, base + 120,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          "History retained", "Idle", "History", "History evidence"])
      let oldID = db.lastInsertedRowID
      for (index, offset) in [0, 60].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, "synthetic-natural-failure", index])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
      }
      return (batch, oldID)
    }
    defer { try? storage.timedWrite("natural retry failure cleanup") { db in
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-natural-failure'")
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ? OR batch_id = ?", arguments: [oldID, batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, _, _ in
      let first = self.card(policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 60), "First", category: "Idle")
      let second = self.card(policy.formatTimestampForPrompt(base + 60), policy.formatTimestampForPrompt(base + 120), "Second", category: "Idle")
      return ([first, second], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    if case .success = result { XCTFail("Expected bounded natural merge failure") }
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldID)?.title, "History retained")
    let cards = storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 120)))
    XCTAssertFalse(cards.contains { $0.batchId == batch && $0.title == "Processing failed" })
  }

  func testInvalidGenerationPreservesSameBatchHistory() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let base = 1_800_120_060
    let policy = TimelineOutputPolicy()
    let (batch, oldID): (Int64, Int64) = try storage.timedWrite("natural retry failure fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 120])
      let batch = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [batch, policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 120), base, base + 120,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          "History retained", "Idle", "History", "History evidence"])
      let oldID = db.lastInsertedRowID
      for (index, offset) in [0, 60].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, "synthetic-validation-failure", index])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
      }
      return (batch, oldID)
    }
    defer { try? storage.timedWrite("natural retry failure cleanup") { db in
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-validation-failure'")
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ? OR batch_id = ?", arguments: [oldID, batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, _, _ in
      return ([], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    if case .success = result { XCTFail("Expected validation failure") }
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldID)?.title, "History retained")
    let cards = storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 120)))
    XCTAssertFalse(cards.contains { $0.batchId == batch && $0.title == "Processing failed" })
  }

  @MainActor
  func testProcessBatchStubProducesOneRealEvent() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let base = 1_800_200_040
    let policy = TimelineOutputPolicy()
    let (batch, oldID, failureID): (Int64, Int64, Int64) = try storage.timedWrite("single pipeline setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 2, base + 122])
      let id = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?)
        """, arguments: [policy.formatTimestampForPrompt(base - 60), policy.formatTimestampForPrompt(base), base - 60, base,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          "Earlier event", "Idle", "Earlier facts", "Earlier detail"])
      let oldID = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [id, policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 180), base, base + 180,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          "Processing failed", "System", "", ""])
      let failureID = db.lastInsertedRowID
      try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,0,0)",
        arguments: [base - 58, "synthetic-single-pipeline"])
      for (index, offset) in [2, 62].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, "synthetic-single-pipeline", index + 1])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return (id, oldID, failureID)
    }
    defer { try? storage.timedWrite("single pipeline cleanup") { db in
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-single-pipeline'")
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [batch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ? OR title = 'Earlier event'", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    var attempts = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      XCTAssertEqual(context.existingCards.count, 1)
      let old = try XCTUnwrap(context.existingCards.first)
      let first = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + 60),
        category: "Idle", subcategory: "", title: "Read article", summary: "Article facts", detailedSummary: "Article detail", distractions: nil, appSites: nil)
      let second = ActivityCardData(startTime: policy.formatTimestampForPrompt(base + 60), endTime: policy.formatTimestampForPrompt(base + 120),
        category: "Idle", subcategory: "", title: "Watch video", summary: "Video facts", detailedSummary: "Video detail", distractions: nil, appSites: nil)
      attempts += 1
      if attempts == 1 {
        return ([old, first, second], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
      }
      XCTAssertEqual(context.correctionCards.map(\.title), ["Earlier event", "Read article", "Watch video"])
      let correction = try TimelineEvidencePolicy.correctionInstruction(context.correctionCards)
      XCTAssertTrue(correction.contains("natural concise title"))
      XCTAssertTrue(correction.contains("Article facts"))
      XCTAssertTrue(correction.contains("Video facts"))
      let rewritten = ActivityCardData(startTime: old.startTime, endTime: second.endTime,
        category: "Idle", subcategory: "", title: "Exploring articles and video",
        summary: "Read an article and watched a related video.", detailedSummary: "Later evidence",
        distractions: nil, appSites: nil)
      return ([rewritten], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let output = try result.get()
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(output.cardIds.count, 1)
    let stored = try XCTUnwrap(storage.fetchTimelineCard(byId: output.cardIds[0]))
    XCTAssertEqual(stored.title, "Exploring articles and video")
    XCTAssertEqual(stored.summary, "Read an article and watched a related video.")
    XCTAssertEqual(stored.startTs, base - 60)
    XCTAssertEqual(stored.endTs, base + 62)
    for fact in ["Earlier event", "Earlier detail", "Read article", "Watch video", "Article detail", "Video detail"] {
      XCTAssertTrue((stored.title + stored.detailedSummary).contains(fact), fact)
    }
    let date = Date(timeIntervalSince1970: Double(base))
    let windowStart = Date(timeIntervalSince1970: Double(base - 60))
    let windowEnd = Date(timeIntervalSince1970: Double(base + 120))
    let day = TimelineActivityLoader.dayPayload(for: date, storageManager: storage, now: date).activities
      .filter { $0.startTime < windowEnd && $0.endTime > windowStart }
    let week = TimelineActivityLoader.activities(in: .containing(date), storageManager: storage)
      .filter { $0.startTime < windowEnd && $0.endTime > windowStart }
    XCTAssertEqual(day.map(\.recordId), [stored.id])
    XCTAssertEqual(week.map(\.recordId), [stored.id])
    XCTAssertNil(storage.fetchTimelineCard(byId: oldID))
    XCTAssertNil(storage.fetchTimelineCard(byId: failureID))
    XCTAssertEqual(TimelineActivityLoader.resolveDisplaySegments(from: day).count, 1)

    let suite = "SameLabelSingleEvent.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let event = TimelineCategory(name: "Synthetic goal", colorHex: "#000000", order: 0, targetEnabled: true)
    let target = FocusTarget(id: UUID(), text: event.name, startedAt: Date(timeIntervalSince1970: Double(base - 120)),
      events: [FocusTargetEvent(id: event.id, name: event.name, details: event.details)])
    defaults.set(try JSONEncoder().encode(target), forKey: "target.current")
    let targetStore = TargetStore(defaults: defaults, storage: storage,
      automaticReminders: AutomaticReminderState(isRecording: false), notify: { _, _, _ in false },
      generate: { _ in
        XCTFail("Goal alignment must use the persisted event group, not a model")
        return "invalid"
      })
    targetStore.synchronize(events: [event])
    targetStore.enqueue(cardIDs: [stored.id])
    await targetStore.waitForEvaluations()
    XCTAssertEqual(targetStore.assessments[stored.id]?.alignment, .severe)
    XCTAssertEqual(targetStore.assessments[stored.id]?.targetText, event.name)
    XCTAssertEqual(targetStore.assessments[stored.id]?.fingerprint, TargetStore.fingerprint(stored))
    XCTAssertEqual(Int(targetStore.assessments[stored.id]?.startTime.timeIntervalSince1970 ?? 0), base - 60)
    XCTAssertEqual(Int(targetStore.assessments[stored.id]?.endTime.timeIntervalSince1970 ?? 0), base + 62)
  }

  func testCaptureContinuityRecognizesRotationButNotAnEarlyStopOrMissingFrame() {
    func frame(_ timestamp: Int, _ path: String, _ index: Int, privacy: Bool = false) -> Screenshot {
      Screenshot(id: Int64(timestamp), capturedAt: timestamp, filePath: path, fileSize: nil,
        idleSecondsAtCapture: 0, isDeleted: false, frameIndex: index, isPrivacyRedacted: privacy)
    }
    let history = [frame(0, "old", 0), frame(598, "old", 598), frame(599, "old", 599)]
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: history, next: frame(600, "new", 0)))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: [frame(0, "old", 0), frame(9, "old", 9)], next: frame(10, "new", 0)))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: [frame(8, "old", 8), frame(9, "old", 9)], next: frame(10, "old", 11)))
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: history, next: frame(600, "new", 0, privacy: true)))
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: history + [frame(600, "new", 0, privacy: true)],
      next: frame(620, "new", 1)))
  }

  func testRewrittenPreviousInterruptionsRemainInDetails() throws {
    let interruption = Distraction(startTime: "9:01 AM", endTime: "9:02 AM", title: "Old side visit", summary: "Old unique fact")
    let old = ActivityCardData(startTime: "9:00 AM", endTime: "9:05 AM", category: "Idle", subcategory: "",
      title: "Earlier", summary: "Earlier", detailedSummary: "Earlier details", distractions: [interruption], appSites: nil)
    let rewritten = ActivityCardData(startTime: "9:00 AM", endTime: "9:10 AM", category: "Idle", subcategory: "",
      title: "Later", summary: "Later", detailedSummary: "Later details", distractions: nil, appSites: nil)
    let output = try TimelineEvidencePolicy.preserveRewrittenFacts([rewritten], previous: [old],
      nearest: Int(Date().timeIntervalSince1970), descriptors: [])
    XCTAssertTrue(output[0].detailedSummary.contains("9:01 AM - 9:02 AM"))
    XCTAssertTrue(output[0].detailedSummary.contains("Old side visit"))
    XCTAssertTrue(output[0].detailedSummary.contains("Old unique fact"))
  }

  func testRepeatedRewritesKeepNaturalProseAndWholeEvidence() throws {
    var previous = card("9:00 AM", "9:05 AM", "First distinct fact", category: "Idle")
    for (end, title, summary) in [("9:10 AM", "A coherent first rewrite", "Combined account one."),
      ("9:15 AM", "A coherent second rewrite", "Combined account two."),
      ("9:20 AM", "A coherent final rewrite", "Combined account three.")] {
      let next = ActivityCardData(startTime: "9:00 AM", endTime: end, category: "Idle", subcategory: "",
        title: title, summary: summary, detailedSummary: "Additional distinct fact \(end)",
        distractions: nil, appSites: nil)
      previous = try XCTUnwrap(TimelineEvidencePolicy.preserveRewrittenFacts([next], previous: [previous],
        nearest: Int(Date().timeIntervalSince1970), descriptors: []).first)
      XCTAssertEqual(previous.title, title)
      XCTAssertEqual(previous.summary, summary)
    }
    for fact in ["First distinct fact", "Additional distinct fact 9:10 AM", "Additional distinct fact 9:15 AM", "Additional distinct fact 9:20 AM"] {
      XCTAssertTrue(previous.detailedSummary.contains(fact))
    }
  }

  func testSameBatchPartialReplacementRollsBack() throws {
    let storage = StorageManager.shared
    let base = 1_800_300_000
    let policy = TimelineOutputPolicy()
    let (batch, oldID): (Int64, Int64) = try storage.timedWrite("same batch partial fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 180])
      let batch = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [batch, policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 180), base, base + 180,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString, "Old same batch", "Idle", "", ""])
      return (batch, db.lastInsertedRowID)
    }
    defer { try? storage.timedWrite("same batch partial cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let shell = TimelineCardShell(startTimestamp: policy.formatTimestampForPrompt(base), endTimestamp: policy.formatTimestampForPrompt(base + 120),
      category: "Idle", subcategory: "", title: "Shorter", summary: "", detailedSummary: "", distractions: nil, appSites: nil)
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups([TimelineCardReplacementGroup(
      from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 120)), cards: [shell])],
      batchId: batch, keepingNewerBatchesCardsStartingAfter: nil))
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldID)?.endTs, base + 180)
    let failureID: Int64 = try storage.timedWrite("same batch failure fixture") { db in
      try db.execute(sql: "UPDATE timeline_cards SET is_deleted = 1 WHERE id = ?", arguments: [oldID])
      try db.execute(sql: """
        INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [batch, policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 180), base, base + 180,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString, "Processing failed", "System", "", ""])
      return db.lastInsertedRowID
    }
    let retry = try storage.replaceTimelineCardGroups([TimelineCardReplacementGroup(
      from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 120)), cards: [shell])],
      batchId: batch, keepingNewerBatchesCardsStartingAfter: nil)
    XCTAssertEqual(retry.insertedIds.count, 1)
    XCTAssertNil(storage.fetchTimelineCard(byId: failureID))
  }

  func testInputInactiveIdleExtendsWithContinuousFramesAndChangesFingerprint() throws {
    let storage = StorageManager.shared
    let base = 1_800_400_020
    let policy = TimelineOutputPolicy()
    let (batch, id): (Int64, Int64) = try storage.timedWrite("idle continuity setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 122, base + 240])
      let batch = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary,metadata)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [policy.formatTimestampForPrompt(base), policy.formatTimestampForPrompt(base + 120), base, base + 120,
          Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          "Idle", "Idle", "Idle", "Idle", #"{"evidenceKind":"inputInactive"}"#])
      return (batch, db.lastInsertedRowID)
    }
    defer { try? storage.timedWrite("idle continuity cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ? OR batch_id = ?", arguments: [id, batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let previous = try XCTUnwrap(storage.fetchTimelineCard(byId: id))
    func frame(_ timestamp: Int, _ path: String, _ index: Int) -> Screenshot {
      Screenshot(id: Int64(timestamp), capturedAt: timestamp, filePath: path, fileSize: nil,
        idleSecondsAtCapture: 1000, isDeleted: false, frameIndex: index)
    }
    let history = [frame(base + 121, "segment", 10)]
    let first = frame(base + 122, "segment", 11)
    XCTAssertTrue(AnalysisManager.canExtendIdle(previous, first: first, history: history, endTs: base + 240))
    XCTAssertFalse(AnalysisManager.canExtendIdle(previous, first: frame(base + 122, "new", 1), history: history, endTs: base + 240))
    XCTAssertFalse(AnalysisManager.canExtendIdle(previous, first: first, history: history, endTs: base + 3720))
    let shell = TimelineCardShell(startTimestamp: policy.formatTimestampForPrompt(base), endTimestamp: policy.formatTimestampForPrompt(base + 240),
      category: "Idle", subcategory: "", title: "Idle", summary: "Idle", detailedSummary: "Idle",
      distractions: nil, appSites: nil, evidenceKind: .inputInactive)
    let result = storage.saveIdleBatchCard(shell, startTs: base, endTs: base + 240, batchId: batch, extendingCardId: id)
    XCTAssertEqual(result.cardId, id)
    let extended = try XCTUnwrap(storage.fetchTimelineCard(byId: id))
    XCTAssertEqual(extended.evidenceKind, .inputInactive)
    XCTAssertNotEqual(TargetStore.fingerprint(previous), TargetStore.fingerprint(extended))
  }

  @MainActor
  func testProcessBatchResumesVisibleAfterSecondPrecisionIdle() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let base = 1_800_500_040
    let policy = TimelineOutputPolicy()
    let (batch, oldID): (Int64, Int64) = try storage.timedWrite("idle to visible setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 32, base + 92])
      let batch = db.lastInsertedRowID
      try db.execute(sql: """
        INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary,metadata)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, arguments: [policy.formatTimestampForPrompt(base - 269), policy.formatTimestampForPrompt(base + 31),
          base - 269, base + 31, Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
          "Idle", "Idle", "Idle", "Idle", #"{"evidenceKind":"inputInactive"}"#])
      let oldID = db.lastInsertedRowID
      for (index, offset) in [32, 92].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, "synthetic-idle-resume", index])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
      }
      return (batch, oldID)
    }
    defer { try? storage.timedWrite("idle to visible cleanup") { db in
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-idle-resume'")
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ? OR batch_id = ?", arguments: [oldID, batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      XCTAssertTrue(context.existingCards.isEmpty)
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + 120),
        category: "Idle", subcategory: "", title: "Visible activity", summary: "Visible fact", detailedSummary: "Visible detail", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let saved = try XCTUnwrap(try result.get().cardIds.first.flatMap { storage.fetchTimelineCard(byId: $0) })
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldID)?.endTs, base + 31)
    XCTAssertEqual(saved.startTs, base + 32)
    XCTAssertEqual(saved.evidenceKind, .visible)
    XCTAssertEqual(saved.title, "Visible activity")
    let secondBatch: Int64 = try storage.timedWrite("idle resume continuation setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 93, base + 153])
      let secondBatch = db.lastInsertedRowID
      for (index, offset) in [93, 153].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, "synthetic-idle-resume-new", index])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [secondBatch, db.lastInsertedRowID])
      }
      return secondBatch
    }
    defer { try? storage.timedWrite("idle resume continuation cleanup") { db in
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [secondBatch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-idle-resume-new'")
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [secondBatch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [secondBatch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [secondBatch])
    } }
    let continuingService = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      let old = try XCTUnwrap(context.existingCards.first)
      XCTAssertEqual(old.title, "Visible activity")
      let next = ActivityCardData(startTime: policy.formatTimestampForPrompt(base + 120),
        endTime: policy.formatTimestampForPrompt(base + 180), category: "Idle", subcategory: "",
        title: "Continued activity", summary: "Continued fact", detailedSummary: "Continued detail", distractions: nil, appSites: nil)
      let rewritten = ActivityCardData(startTime: old.startTime, endTime: next.endTime,
        category: "Idle", subcategory: "", title: "Continued visible activity",
        summary: "The visible activity continued.", detailedSummary: next.detailedSummary,
        distractions: nil, appSites: nil)
      return ([rewritten], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let continued: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      continuingService.processBatch(secondBatch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let combined = try XCTUnwrap(try continued.get().cardIds.first.flatMap { storage.fetchTimelineCard(byId: $0) })
    XCTAssertEqual(combined.startTs, base + 32)
    XCTAssertEqual(combined.endTs, base + 153)
    XCTAssertEqual(combined.title, "Continued visible activity")
    XCTAssertTrue(combined.detailedSummary.contains("Visible detail"))
    XCTAssertTrue(combined.detailedSummary.contains("Continued detail"))
    XCTAssertNil(storage.fetchTimelineCard(byId: saved.id))
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldID)?.endTs, base + 31)
    let thirdBatch: Int64 = try storage.timedWrite("third continuation setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 181, base + 241])
      let third = db.lastInsertedRowID
      for (index, offset) in [181, 241].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, "synthetic-idle-resume-third", index])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [third, db.lastInsertedRowID])
      }
      return third
    }
    defer { try? storage.timedWrite("third continuation cleanup") { db in
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [thirdBatch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'synthetic-idle-resume-third'")
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [thirdBatch])
      try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [thirdBatch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [thirdBatch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [thirdBatch])
    } }
    let thirdService = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      let old = try XCTUnwrap(context.existingCards.first)
      XCTAssertEqual(old.title, "Continued visible activity")
      XCTAssertEqual(old.summary, "The visible activity continued.")
      XCTAssertTrue(old.detailedSummary.contains("Visible detail"))
      let rewritten = ActivityCardData(startTime: old.startTime, endTime: policy.formatTimestampForPrompt(base + 300),
        category: "Idle", subcategory: "", title: "A natural third title", summary: "A natural third account.",
        detailedSummary: "Third distinct detail", distractions: nil, appSites: nil)
      return ([rewritten], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let thirdResult: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      thirdService.processBatch(thirdBatch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let final = try XCTUnwrap(try thirdResult.get().cardIds.first.flatMap { storage.fetchTimelineCard(byId: $0) })
    XCTAssertEqual(final.title, "A natural third title")
    XCTAssertEqual(final.summary, "A natural third account.")
    XCTAssertEqual(final.startTs, base + 32)
    XCTAssertEqual(final.endTs, base + 241)
    for fact in ["Visible detail", "Continued detail", "Third distinct detail"] {
      XCTAssertTrue(final.detailedSummary.contains(fact))
    }
    let suite = "ThreeBatchEvaluation.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let event = TimelineCategory(name: "Three batch goal", colorHex: "#000000", order: 0, targetEnabled: true)
    let target = FocusTarget(id: UUID(), text: event.name, startedAt: Date(timeIntervalSince1970: Double(base - 120)),
      events: [FocusTargetEvent(id: event.id, name: event.name, details: event.details)])
    defaults.set(try JSONEncoder().encode(target), forKey: "target.current")
    let targetStore = TargetStore(defaults: defaults, storage: storage,
      automaticReminders: AutomaticReminderState(isRecording: false), notify: { _, _, _ in false }, generate: { _ in
        XCTFail("Continued event alignment must use its persisted group")
        return "invalid"
      })
    targetStore.synchronize(events: [event])
    targetStore.enqueue(cardIDs: [final.id])
    await targetStore.waitForEvaluations()
    XCTAssertEqual(targetStore.assessments[final.id]?.alignment, .severe)
    XCTAssertEqual(targetStore.assessments[final.id]?.targetText, event.name)
    XCTAssertEqual(targetStore.assessments[final.id]?.fingerprint, TargetStore.fingerprint(final))
    XCTAssertEqual(Int(targetStore.assessments[final.id]?.startTime.timeIntervalSince1970 ?? 0), base + 32)
    XCTAssertEqual(Int(targetStore.assessments[final.id]?.endTime.timeIntervalSince1970 ?? 0), base + 241)
  }


  func testCurrentSessionBoundaryRejectsOldRotationButKeepsSameSessionRotation() {
    let boundaries = TimelineCaptureBoundaries(observedSince: 1200)
    let old = [Screenshot(id: 1, capturedAt: 540, filePath: "old", fileSize: nil,
      idleSecondsAtCapture: nil, isDeleted: false, frameIndex: 0),
      Screenshot(id: 2, capturedAt: 1140, filePath: "old", fileSize: nil,
        idleSecondsAtCapture: nil, isDeleted: false, frameIndex: 10)]
    let next = Screenshot(id: 3, capturedAt: 1200, filePath: "new", fileSize: nil,
      idleSecondsAtCapture: nil, isDeleted: false, frameIndex: 0)
    XCTAssertEqual(boundaries.continuity(from: 1140, to: 1200), false)
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: old, next: next,
      recordedContinuity: boundaries.continuity(from: 1140, to: 1200)))
    XCTAssertNil(boundaries.continuity(from: 540, to: 1140))
    let same = TimelineCaptureBoundaries(observedSince: 0)
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: old, next: next,
      recordedContinuity: same.continuity(from: 1140, to: 1200)))
  }


  func testContinuousSuffixIncludesRedactionButRespectsStopsMissingFramesAndDayBoundary() {
    func frame(_ timestamp: Int, index: Int, privacy: Bool = false) -> Screenshot {
      Screenshot(id: Int64(timestamp), capturedAt: timestamp, filePath: "suffix", fileSize: nil,
        idleSecondsAtCapture: 0, isDeleted: false, frameIndex: index, isPrivacyRedacted: privacy)
    }
    let frames = [frame(0, index: 0), frame(20, index: 1), frame(40, index: 2), frame(60, index: 3)]
    XCTAssertEqual(TimelineEvidencePolicy.continuousCaptureSuffix(frames,
      recordedContinuity: { _, _ in true }).map(\.capturedAt), [0, 20, 40, 60])
    XCTAssertEqual(TimelineEvidencePolicy.continuousCaptureSuffix(frames,
      recordedContinuity: { previous, _ in previous == 20 ? false : true }).map(\.capturedAt), [40, 60])
    XCTAssertEqual(TimelineEvidencePolicy.continuousCaptureSuffix([
      frames[0], frame(20, index: 1, privacy: true), frames[2], frames[3]],
      recordedContinuity: { _, _ in true }).map(\.capturedAt), [0, 20, 40, 60])
    XCTAssertEqual(TimelineEvidencePolicy.continuousCaptureSuffix([frames[0], frames[2], frames[3]],
      recordedContinuity: { _, _ in true }).map(\.capturedAt), [40, 60])
    var calendar = Calendar.current
    calendar.timeZone = .current
    let fourAM = Int(calendar.date(from: DateComponents(year: 2027, month: 1, day: 20, hour: 4))!.timeIntervalSince1970)
    XCTAssertEqual(TimelineEvidencePolicy.continuousCaptureSuffix([
      frame(fourAM - 20, index: 0), frame(fourAM, index: 1), frame(fourAM + 20, index: 2)],
      recordedContinuity: { _, _ in true }).map(\.capturedAt), [fourAM, fourAM + 20])
  }

  func testProcessBatchContinuesLatestEventAfterInterleavedCaptureHistory() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let base = 1_800_000_000
    let policy = TimelineOutputPolicy()
    let path = "interleaved-history-\(UUID().uuidString)"
    let (batch, earlierID, latestID): (Int64, Int64, Int64) = try storage.timedWrite("interleaved history setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 701, base + 1001])
      let batch = db.lastInsertedRowID
      func insertCard(start: Int, end: Int, title: String) throws -> Int64 {
        try db.execute(sql: """
          INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary,metadata)
          VALUES (?,?,?,?,?,?,?,?,?,?)
          """, arguments: [policy.formatTimestampForPrompt(base + start), policy.formatTimestampForPrompt((base + end) / 60 * 60 + 60),
            base + start, base + end, Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
            title, "Idle", title, title + " detail", #"{"evidenceKind":"visible"}"#])
        return db.lastInsertedRowID
      }
      let earlier = try insertCard(start: 0, end: 300, title: "Earlier separate event")
      let latest = try insertCard(start: 381, end: 681, title: "Latest continuous event")
      func insertFrame(_ offset: Int, stream: String, index: Int, inBatch: Bool = false) throws {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, path + stream, index])
        if inBatch {
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
        }
      }
      for offset in stride(from: 0, through: 360, by: 20) {
        try insertFrame(offset, stream: "A", index: offset / 20)
      }
      for offset in stride(from: 321, through: 1001, by: 20) {
        try insertFrame(offset, stream: "B", index: (offset - 321) / 20, inBatch: offset >= 701)
      }
      return (batch, earlier, latest)
    }
    defer { try? storage.timedWrite("interleaved history cleanup") { db in
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ? OR id IN (?,?)", arguments: [batch, earlierID, latestID])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path IN (?,?)", arguments: [path + "A", path + "B"])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      calls += 1
      XCTAssertEqual(context.existingCards.map(\.title), ["Latest continuous event"])
      let first = try XCTUnwrap(context.existingCards.first)
      let combined = ActivityCardData(startTime: first.startTime, endTime: policy.formatTimestampForPrompt(base + 1020),
        category: "Idle", subcategory: "", title: "Natural continued event", summary: "Coherent combined account",
        detailedSummary: "New batch detail", distractions: nil, appSites: nil)
      return ([combined], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let ids = try result.get().cardIds
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(ids.count, 1)
    let saved = try XCTUnwrap(ids.first.flatMap { storage.fetchTimelineCard(byId: $0) })
    XCTAssertEqual(saved.startTs, base + 381)
    XCTAssertEqual(saved.endTs, base + 1001)
    XCTAssertEqual(saved.title, "Natural continued event")
    XCTAssertTrue(saved.detailedSummary.contains("Latest continuous event detail"))
    XCTAssertTrue(saved.detailedSummary.contains("New batch detail"))
    XCTAssertFalse(saved.detailedSummary.contains("Earlier separate event"))
    XCTAssertNil(storage.fetchTimelineCard(byId: latestID))
    XCTAssertNotNil(storage.fetchTimelineCard(byId: earlierID))
  }

  func testLegacyJPEGContinuityUsesCadenceAndKnownStop() {
    func jpeg(_ timestamp: Int) -> Screenshot {
      Screenshot(id: Int64(timestamp), capturedAt: timestamp, filePath: "legacy-\(timestamp).jpg",
        fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false)
    }
    let history = [jpeg(0), jpeg(60)]
    XCTAssertTrue(TimelineEvidencePolicy.captureContinues(history: history, next: jpeg(120)))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: history, next: jpeg(120), recordedContinuity: false))
    XCTAssertFalse(TimelineEvidencePolicy.captureContinues(history: history, next: jpeg(152)))
  }

}
