import Foundation
import XCTest
@testable import Dayflow

final class TimelineCategoryWriteTests: XCTestCase {
  private var previousArguments: [String: Any] = [:]
  private let base = 1_803_000_000 / 60 * 60
  private let eventName = "Synthetic switchable event"

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

  private func setEnabled(_ enabled: Bool) throws {
    let event = TimelineCategory(name: eventName, colorHex: "#FFFFFF", order: 0,
      targetEnabled: true, eventEnabled: enabled)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var arguments = AppStoragePaths.defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments[CategoryStore.StoreKeys.categories] = try encoder.encode([event])
    AppStoragePaths.defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
  }

  private func card(start: Int, end: Int, category: String) -> ActivityCardData {
    let output = TimelineOutputPolicy()
    return ActivityCardData(startTime: output.formatTimestampForPrompt(start),
      endTime: output.formatTimestampForPrompt(end), category: category, subcategory: "",
      title: "New evidence", summary: "New summary", detailedSummary: "New details",
      distractions: nil, appSites: nil, evidenceKind: .visible)
  }

  func testHistoricalIdentityDoesNotCollapseDisabledOrUnknownLabelsIntoIdle() {
    XCTAssertFalse(TimelineCategoryWritePolicy.sameHistoricalCategory(eventName, "Idle"))
    XCTAssertFalse(TimelineCategoryWritePolicy.sameHistoricalCategory("Deleted event", "Other"))
    XCTAssertTrue(TimelineCategoryWritePolicy.sameHistoricalCategory(" OTHER ", "Idle"))
    XCTAssertTrue(TimelineCategoryWritePolicy.sameHistoricalCategory(" STUDY ", "Study"))
  }

  func testCommitPolicyUsesLatestSwitchWithoutMutatingProviderResult() throws {
    let generated = card(start: base, end: base + 120, category: eventName)
    try setEnabled(true)
    XCTAssertEqual(try TimelineCategoryWritePolicy.current().cardsForCommit(
      [generated], history: [], nearest: base).first?.category, eventName)
    try setEnabled(false)
    XCTAssertEqual(try TimelineCategoryWritePolicy.current().cardsForCommit(
      [generated], history: [], nearest: base).first?.category, "Idle")
    XCTAssertEqual(generated.category, eventName)
  }

  private struct Fixture {
    let batch: Int64
    let oldID: Int64?
    let path: String
  }

  private func fixture(historyEnd: Int? = nil, pending: Bool = false) throws -> Fixture {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let path = "synthetic-category-switch-\(UUID().uuidString)"
    let output = TimelineOutputPolicy()
    return try storage.timedWrite("category switch fixture") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)",
        arguments: [base, base + 180])
      let batch = db.lastInsertedRowID
      var oldID: Int64?
      if let historyEnd {
        try db.execute(sql: """
          INSERT INTO timeline_cards(start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
          VALUES (?,?,?,?,?,?,?,?,?)
          """, arguments: [output.formatTimestampForPrompt(base - 120), output.formatTimestampForPrompt(historyEnd),
            base - 120, historyEnd, Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString,
            "Published history", eventName, "Original summary", "Original details"])
        oldID = db.lastInsertedRowID
      }
      var screenshotIDs: [Int64] = []
      for (index, offset) in [-120, -60, 0, 60, 120, 180].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
          arguments: [base + offset, path, index])
        let id = db.lastInsertedRowID
        screenshotIDs.append(id)
        if offset >= 0 {
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, id])
        }
      }
      if pending {
        let pendingCard = card(start: base - 120, end: base, category: eventName)
        let json = String(decoding: try JSONEncoder().encode(pendingCard), as: UTF8.self)
        try db.execute(sql: """
          INSERT INTO pending_timeline_evidence(batch_id,start_ts,end_ts,card_json,first_screenshot_id,last_screenshot_id)
          VALUES (?,?,?,?,?,?)
          """, arguments: [batch, base - 120, base - 60, json, screenshotIDs[0], screenshotIDs[1]])
        let id = db.lastInsertedRowID
        for source in screenshotIDs.prefix(2) {
          try db.execute(sql: "INSERT INTO pending_timeline_sources(pending_id,screenshot_id) VALUES (?,?)", arguments: [id, source])
        }
      }
      return Fixture(batch: batch, oldID: oldID, path: path)
    }
  }

  private func clean(_ fixture: Fixture) {
    try? StorageManager.shared.timedWrite("category switch cleanup") { db in
      try db.execute(sql: "DELETE FROM pending_timeline_evidence WHERE batch_id = ?", arguments: [fixture.batch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ? OR id = ?", arguments: [fixture.batch, fixture.oldID ?? -1])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [fixture.batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [fixture.path])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [fixture.batch])
    }
  }

  private func process(_ fixture: Fixture, duringGeneration: @escaping (ActivityGenerationContext) throws -> Void,
    beforeCommit: (() -> Void)? = nil, outputStart: Int? = nil) async throws -> ProcessedBatchResult {
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      try duringGeneration(context)
      return ([self.card(start: outputStart ?? self.base - 120, end: self.base + 240, category: self.eventName)],
        [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    }, beforeTimelineCommit: beforeCommit)
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(fixture.batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    return try result.get()
  }

  func testInFlightDisableNormalizesNewOutputAndPreservesPublishedHistory() async throws {
    try setEnabled(true)
    let fixture = try fixture(historyEnd: base)
    defer { clean(fixture) }
    let result = try await process(fixture, duringGeneration: { context in
      XCTAssertTrue(context.categories.contains { $0.name == self.eventName })
      try self.setEnabled(false)
    })
    XCTAssertFalse(result.cardIds.isEmpty)
    XCTAssertTrue(result.cards.allSatisfy { $0.category == "Idle" })
    let old = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: fixture.oldID!))
    XCTAssertEqual(old.id, fixture.oldID!)
    XCTAssertEqual(old.category, eventName)
    XCTAssertEqual(old.endTs, base)
    XCTAssertEqual(old.title, "Published history")
    XCTAssertEqual(old.detailedSummary, "Original details")
    for id in result.cardIds {
      let saved = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: id))
      XCTAssertEqual(saved.category, "Idle")
      XCTAssertGreaterThanOrEqual(saved.startTs, old.endTs)
    }
  }

  func testCommitHookDisableProtectsSecondPrecisionHistoryInCurrentBatch() async throws {
    try setEnabled(true)
    let fixture = try fixture(historyEnd: base + 1)
    defer { clean(fixture) }
    let result = try await process(fixture, duringGeneration: { _ in }, beforeCommit: {
      do { try self.setEnabled(false) } catch { XCTFail("\(error)") }
    })
    XCTAssertFalse(result.cardIds.isEmpty)
    let old = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: fixture.oldID!))
    XCTAssertEqual(old.id, fixture.oldID!)
    XCTAssertEqual(old.category, eventName)
    XCTAssertEqual(old.endTs, base + 1)
    for id in result.cardIds {
      let saved = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: id))
      XCTAssertEqual(saved.category, "Idle")
      XCTAssertGreaterThanOrEqual(saved.startTs, base + 60)
    }
  }

  func testDisabledHistoryAndPendingAreNotFedBackOrExtendedByNewIdle() async throws {
    try setEnabled(false)
    let fixture = try fixture(historyEnd: base, pending: true)
    defer { clean(fixture) }
    let result = try await process(fixture, duringGeneration: { context in
      XCTAssertFalse(context.categories.contains { $0.name == self.eventName })
      XCTAssertFalse(context.existingCards.contains { $0.category == self.eventName })
    }, outputStart: base)
    XCTAssertFalse(result.cardIds.isEmpty)
    XCTAssertNotNil(StorageManager.shared.fetchTimelineCard(byId: fixture.oldID!))
    for id in result.cardIds {
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: id)).startTs, base)
    }
  }

  func testRenamedDisabledDefinitionStillProtectsOriginalHistory() async throws {
    let renamed = TimelineCategory(name: "Renamed disabled event", colorHex: "#FFFFFF", order: 0,
      eventEnabled: false)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var arguments = AppStoragePaths.defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments[CategoryStore.StoreKeys.categories] = try encoder.encode([renamed])
    AppStoragePaths.defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    let fixture = try fixture(historyEnd: base, pending: true)
    defer { clean(fixture) }
    let result = try await process(fixture, duringGeneration: { context in
      XCTAssertFalse(context.existingCards.contains { $0.category == self.eventName })
    }, outputStart: base)
    let old = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: fixture.oldID!))
    XCTAssertEqual(old.category, eventName)
    XCTAssertEqual(old.endTs, base)
    XCTAssertFalse(result.cardIds.isEmpty)
    for id in result.cardIds {
      let saved = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: id))
      XCTAssertEqual(saved.category, "Idle")
      XCTAssertGreaterThanOrEqual(saved.startTs, base)
    }
  }

  func testPendingPublisherNormalizesSwitchChangedAtCommit() async throws {
    try setEnabled(true)
    let fixture = try fixture(pending: true)
    defer { clean(fixture) }
    let pending = try XCTUnwrap(StorageManager.shared.pendingTimelineEvidence().first {
      $0.batchId == fixture.batch
    })
    let ids = try await LLMService.publishEligiblePending(pending, beforeCommit: {
      do { try self.setEnabled(false) } catch { XCTFail("\(error)") }
    })
    XCTAssertEqual(ids.count, 1)
    let saved = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: ids[0]))
    XCTAssertEqual(saved.category, "Idle")
    XCTAssertEqual(saved.startTs, pending.startTs)
    XCTAssertEqual(saved.endTs, pending.endTs)
    XCTAssertFalse(StorageManager.shared.pendingTimelineEvidence().contains { $0.id == pending.id })
  }

  func testPendingPublisherDoesNotRewriteHistoryDisabledAtCommit() async throws {
    try setEnabled(true)
    let fixture = try fixture(historyEnd: base, pending: true)
    defer { clean(fixture) }
    let pending = try XCTUnwrap(StorageManager.shared.pendingTimelineEvidence().first {
      $0.batchId == fixture.batch
    })
    let ids = try await LLMService.publishEligiblePending(pending, beforeCommit: {
      do { try self.setEnabled(false) } catch { XCTFail("\(error)") }
    })
    XCTAssertTrue(ids.isEmpty)
    let old = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: fixture.oldID!))
    XCTAssertEqual(old.id, fixture.oldID!)
    XCTAssertEqual(old.category, eventName)
    XCTAssertEqual(old.endTs, base)
    XCTAssertTrue(StorageManager.shared.pendingTimelineEvidence().contains { $0.id == pending.id })
  }

  func testFullyProtectedBatchDoesNotReplaceHistoryWithFallbackOrFailure() async throws {
    try setEnabled(false)
    let fixture = try fixture(historyEnd: base + 240)
    defer { clean(fixture) }
    let result = try await process(fixture, duringGeneration: { _ in }, outputStart: base)
    XCTAssertTrue(result.cardIds.isEmpty)
    XCTAssertTrue(result.cards.isEmpty)
    let old = try XCTUnwrap(StorageManager.shared.fetchTimelineCard(byId: fixture.oldID!))
    XCTAssertEqual(old.category, eventName)
    XCTAssertEqual(old.endTs, base + 240)
  }
}
