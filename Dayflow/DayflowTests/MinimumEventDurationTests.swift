import Foundation
import GRDB
import XCTest
@testable import Dayflow

final class MinimumEventDurationTests: XCTestCase {
  @MainActor
  func testFiveMinuteSettingDoesNotPublishOneMinuteRetry() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let priorArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = priorArguments
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(priorArguments, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    var base = (Int(Date().timeIntervalSince1970) + 3600) / 60 * 60
    if Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      != Date(timeIntervalSince1970: Double(base + 360)).getDayInfoFor4AMBoundary().dayString {
      base += 3600
    }
    let batch = try storage.timedWrite("minimum duration test setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 60])
      let id = db.lastInsertedRowID
      for (index, offset) in [0, 60].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, "minimum-duration-test", index])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return id
    }
    defer { try? storage.timedWrite("minimum duration test cleanup") { db in
      try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [batch])
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = 'minimum-duration-test'")
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      let continuing = !context.existingCards.isEmpty
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + (continuing ? 360 : 120)), category: "Idle", subcategory: "", title: continuing ? "Combined event" : "One minute", summary: "Observed activity", detailedSummary: continuing ? "Later evidence" : "Observed evidence", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let published = try result.get().cardIds
    XCTAssertTrue(published.isEmpty, "A one-minute result must remain pending at the five-minute setting")
    XCTAssertFalse(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 60))).contains { $0.title == "One minute" })
    XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
    let nextBatch = try storage.timedWrite("minimum duration continuation setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 120, base + 300])
      let id = db.lastInsertedRowID
      for (index, offset) in [120, 180, 240, 300].enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, "minimum-duration-test", index + 2])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return id
    }
    defer { try? storage.timedWrite("minimum duration continuation cleanup") { db in
      try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [nextBatch])
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [nextBatch])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [nextBatch])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [nextBatch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [nextBatch])
    } }
    let middle = try XCTUnwrap(storage.fetchScreenshotsInTimeRange(startTs: base + 180, endTs: base + 180).first { $0.filePath == "minimum-duration-test" })
    var commitNotifications = 0
    let observer = NotificationCenter.default.addObserver(forName: .timelineCardsDidCommit, object: nil, queue: nil) { _ in commitNotifications += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    let deletingService = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, _, _ in
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + 360), category: "Idle", subcategory: "", title: "Combined event", summary: "Observed activity", detailedSummary: "Later evidence", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    }, beforeTimelineCommit: {
      try? storage.timedWrite("delete intermediate frame before commit") { db in
        try db.execute(sql: "UPDATE screenshots SET is_deleted = 1 WHERE id = ?", arguments: [middle.id])
      }
    })
    let raced: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      deletingService.processBatch(nextBatch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    guard case .failure(let raceError) = raced else { XCTFail("Deleted source must abort commit"); return }
    guard case TimelineCardReplacementError.sourceEvidenceChanged = raceError else { XCTFail("Unexpected race error: \(raceError)"); return }
    XCTAssertEqual(commitNotifications, 0)
    XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
    XCTAssertFalse(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 300))).contains { $0.batchId == nextBatch })
    try storage.timedWrite("restore synthetic source") { db in
      try db.execute(sql: "UPDATE screenshots SET is_deleted = 0 WHERE id = ?", arguments: [middle.id])
    }
    try storage.timedWrite("minimum forced rollback setup") { db in
      try db.execute(sql: """
        CREATE TRIGGER minimum_forced_rollback BEFORE INSERT ON timeline_cards
        WHEN NEW.title = 'Combined event' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END
        """)
    }
    defer { try? storage.timedWrite("minimum forced rollback cleanup") { db in
      try db.execute(sql: "DROP TRIGGER IF EXISTS minimum_forced_rollback")
    } }
    let failed: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(nextBatch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    if case .success = failed { XCTFail("Forced atomic insert failure must fail the batch") }
    XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
    XCTAssertFalse(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 300))).contains { $0.title == "Combined event" })
    try storage.timedWrite("minimum remove forced rollback") { db in
      try db.execute(sql: "DROP TRIGGER minimum_forced_rollback")
    }
    let nextResult: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(nextBatch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let id = try XCTUnwrap(try nextResult.get().cardIds.first)
    let combined = try XCTUnwrap(storage.fetchTimelineCard(byId: id))
    XCTAssertEqual(combined.startTs, base)
    XCTAssertEqual(combined.endTs, base + 300)
    XCTAssertEqual(combined.title, "Combined event")
    XCTAssertTrue(combined.detailedSummary.contains("Observed evidence"))
    XCTAssertTrue(combined.detailedSummary.contains("Later evidence"))
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batch })

  }

  @MainActor
  func testAnalysisBatchesPublishThenRefreshAndEvaluate() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = previousArguments
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    let now = Int(Date().timeIntervalSince1970)
    var base = (now - 1800) / 60 * 60
    if Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      != Date(timeIntervalSince1970: Double(base + 600)).getDayInfoFor4AMBoundary().dayString {
      base -= 3600
    }
    let path = "minimum-manager-\(UUID().uuidString)"
    func insert(_ offsets: [Int]) throws {
      try storage.timedWrite("minimum manager evidence") { db in
        for offset in offsets {
          try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)",
            arguments: [base + offset, path, offset / 60])
        }
      }
    }
    defer { try? storage.timedWrite("minimum manager cleanup") { db in
      try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id IN (SELECT batch_id FROM batch_screenshots WHERE screenshot_id IN (SELECT id FROM screenshots WHERE file_path = ?)))", arguments: [path])
      try db.execute(sql: "DELETE FROM observations WHERE batch_id IN (SELECT batch_id FROM batch_screenshots WHERE screenshot_id IN (SELECT id FROM screenshots WHERE file_path = ?))", arguments: [path])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id IN (SELECT batch_id FROM batch_screenshots WHERE screenshot_id IN (SELECT id FROM screenshots WHERE file_path = ?))", arguments: [path])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id IN (SELECT batch_id FROM batch_screenshots WHERE screenshot_id IN (SELECT id FROM screenshots WHERE file_path = ?))", arguments: [path])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, context, _ in
      func item(_ start: Int, _ end: Int, _ category: String, _ title: String, _ detail: String) -> ActivityCardData {
        ActivityCardData(startTime: policy.formatTimestampForPrompt(base + start), endTime: policy.formatTimestampForPrompt(base + end),
          category: category, subcategory: "", title: title, summary: title, detailedSummary: detail, distractions: nil, appSites: nil)
      }
      let cards = context.existingCards.isEmpty
        ? [item(0, 240, "Work", "Earlier work", "Work evidence"), item(240, 360, "Idle", "Early tail", "Tail evidence")]
        : [item(0, 720, "Idle", "Natural continued event", "Later evidence")]
      return (cards, [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let firstProcessed = expectation(description: "continuous run is published and evaluated")
    let published = expectation(description: "published event enqueued")
    let refreshed = expectation(description: "timeline committed")
    refreshed.expectedFulfillmentCount = 2
    let observer = NotificationCenter.default.addObserver(forName: .timelineCardsDidCommit, object: nil, queue: nil) { _ in refreshed.fulfill() }
    defer { NotificationCenter.default.removeObserver(observer) }
    let suite = "MinimumDurationEvaluation.\(UUID().uuidString)"
    let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { targetDefaults.removePersistentDomain(forName: suite) }
    let event = TimelineCategory(name: "Synthetic target", colorHex: "#000000", order: 0, targetEnabled: true)
    let target = FocusTarget(id: UUID(), text: event.name, startedAt: Date(timeIntervalSince1970: Double(base - 60)),
      events: [FocusTargetEvent(id: event.id, name: event.name, details: event.details)])
    targetDefaults.set(try JSONEncoder().encode(target), forKey: "target.current")
    let targetStore = TargetStore(defaults: targetDefaults, storage: storage,
      automaticReminders: AutomaticReminderState(isRecording: false), notify: { _, _, _ in false }, generate: { _ in
        XCTFail("Goal alignment must be determined locally from event membership")
        return "invalid"
      })
    targetStore.synchronize(events: [event])
    var evaluations = 0
    let manager = AnalysisManager(store: storage, llmService: service, evidenceCaptureStartTs: base - 1000, evaluate: { ids in
      XCTAssertFalse(ids.isEmpty, "A continuous run reaching the stability window must not be dropped into per-card pending")
      targetStore.enqueue(cardIDs: ids)
      evaluations += 1
      if evaluations == 1 { firstProcessed.fulfill() }
      else { published.fulfill() }
    })
    try insert([0, 60, 120, 180, 240, 300])
    manager.triggerAnalysisNow()
    await fulfillment(of: [firstProcessed], timeout: 5)
    XCTAssertEqual(storage.pendingTimelineEvidence().filter { $0.startTs >= base && $0.endTs <= base + 300 }.count, 0)
    let firstPublished = storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)),
      to: Date(timeIntervalSince1970: Double(base + 300))).filter { ($0.startTs ?? Int.min) >= base && ($0.endTs ?? Int.max) <= base + 300 }
    XCTAssertEqual(firstPublished.count, 1)
    XCTAssertEqual(firstPublished.first?.startTs, base)
    XCTAssertEqual(firstPublished.first?.endTs, base + 300)
    try insert([360, 420, 480, 540, 600, 660])
    manager.triggerAnalysisNow()
    await fulfillment(of: [published, refreshed], timeout: 5)
    await targetStore.waitForEvaluations()
    let selectedDate = Date(timeIntervalSince1970: Double(base + 240))
    let day = TimelineActivityLoader.dayPayload(for: selectedDate, storageManager: storage, now: selectedDate).activities
    let week = TimelineActivityLoader.activities(in: TimelineWeekRange.containing(selectedDate), storageManager: storage)
    let saved = try XCTUnwrap(day.first { $0.title == "Natural continued event" }, "Visible titles: \(day.map(\.title))")
    XCTAssertTrue(week.contains { $0.recordId == saved.recordId })
    XCTAssertEqual(Int(saved.endTime.timeIntervalSince(saved.startTime)), 300)
    let assessment = try XCTUnwrap(saved.recordId.flatMap { targetStore.assessment(for: $0) })
    XCTAssertEqual(assessment.alignment, .severe)
    XCTAssertEqual(assessment.targetText, event.name)
    XCTAssertFalse(assessment.reminder.isEmpty)
    // Short switches are preserved as facts inside the published event, not left
    // behind as independent pending cards that a later batch cannot continue.
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.startTs >= base && $0.endTs <= base + 600 })
    let persisted = storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)),
      to: Date(timeIntervalSince1970: Double(base + 720)))
    let allDetails = persisted.map(\.detailedSummary).joined(separator: "\n")
    XCTAssertTrue(allDetails.contains("Work evidence"))
    XCTAssertTrue(allDetails.contains("Tail evidence"))
  }


  @MainActor
  func testEverySettingUsesExactEvidenceSeconds() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    let policy = TimelineOutputPolicy()
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    for (thresholdIndex, threshold) in [60, 300, 600, 900].enumerated() {
      var args = original
      args[AnalysisPreferences.intervalKey] = threshold
      defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
      for (caseIndex, duration) in [threshold - 1, threshold].enumerated() {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2027, month: 6, day: 1 + thresholdIndex * 2 + caseIndex, hour: 12)))
        let base = Int(date.timeIntervalSince1970)
        let path = "minimum-interval-\(UUID().uuidString)"
        let offsets = Array(stride(from: 0, to: duration, by: 60)) + [duration]
        let batch = try storage.timedWrite("minimum interval setup") { db -> Int64 in
          try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + duration])
          let id = db.lastInsertedRowID
          for (index, offset) in offsets.enumerated() {
            try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path, index])
            try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
          }
          return id
        }
        defer { try? storage.timedWrite("minimum interval cleanup") { db in
          try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
          try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
          try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
          try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
          try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
        } }
        let outputEnd = base + duration / 60 * 60 + 60
        let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, _, _ in
          let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(outputEnd),
            category: "Idle", subcategory: "", title: "Threshold \(threshold)", summary: "Synthetic", detailedSummary: "Evidence", distractions: nil, appSites: nil)
          return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
        })
        let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
          service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
        }
        let ids = try result.get().cardIds
        XCTAssertEqual(ids.count, duration == threshold ? 1 : 0, "threshold \(threshold), duration \(duration)")
        if let id = ids.first {
          let card = try XCTUnwrap(storage.fetchTimelineCard(byId: id))
          XCTAssertEqual(card.endTs - card.startTs, duration)
        } else {
          XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
        }
      }
    }
  }


  @MainActor
  func testIdleRetryWaitsForFiveMinutesAndContinuesWithoutProvider() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    let base = Int(Date().timeIntervalSince1970 - 1800) / 60 * 60
    let path = "minimum-idle-\(UUID().uuidString)"
    let batches = try storage.timedWrite("idle minimum setup") { db -> [Int64] in
      var ids: [Int64] = []
      for (start, end) in [(0, 60), (70, 300)] {
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + start, base + end])
        ids.append(db.lastInsertedRowID)
      }
      for offset in stride(from: -300, through: 300, by: 10) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,idle_seconds_at_capture,is_privacy_redacted) VALUES (?,?,?,?,0)",
          arguments: [base + offset, path, (offset + 300) / 10, 2000])
        let screenshotId = db.lastInsertedRowID
        if offset >= 0 {
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [offset <= 60 ? ids[0] : ids[1], screenshotId])
        }
      }
      return ids
    }
    defer { try? storage.timedWrite("idle minimum cleanup") { db in
      for id in batches {
        try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [id])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { _, _, _ in
      XCTFail("Input-inactive shortcut should not call provider")
      throw ClaudeOutputValidationError.emptyCards
    })
    let middle = try XCTUnwrap(storage.screenshotsForBatch(batches[0]).first { $0.capturedAt == base + 30 })
    var deleted = false
    var incorrectlyEvaluated = false
    let racingManager = AnalysisManager(store: storage, llmService: service, evidenceCaptureStartTs: base - 300,
      idlePixels: { _ in
        if !deleted {
          deleted = true
          try? storage.timedWrite("delete idle classifier input") { db in
            try db.execute(sql: "UPDATE screenshots SET is_deleted = 1 WHERE id = ?", arguments: [middle.id])
          }
        }
        return [UInt8](repeating: 100, count: 96 * 54)
      }, evaluate: { _ in incorrectlyEvaluated = true })
    let raced: Result<Void, Error> = await withCheckedContinuation { continuation in
      racingManager.reprocessBatch(batches[0], stepHandler: { _ in }) { continuation.resume(returning: $0) }
    }
    guard case .failure(let error) = raced else { XCTFail("Deleted Idle source must abort"); return }
    guard case TimelineCardReplacementError.sourceEvidenceChanged = error else { XCTFail("Unexpected error: \(error)"); return }
    XCTAssertFalse(incorrectlyEvaluated)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batches[0] })
    try storage.timedWrite("restore synthetic Idle source") { db in
      try db.execute(sql: "UPDATE screenshots SET is_deleted = 0 WHERE id = ?", arguments: [middle.id])
    }
    let evaluated = expectation(description: "idle evaluated only after publication")
    let manager = AnalysisManager(store: storage, llmService: service, evidenceCaptureStartTs: base - 300,
      idlePixels: { _ in [UInt8](repeating: 100, count: 96 * 54) }, evaluate: { ids in
        XCTAssertFalse(ids.isEmpty)
        evaluated.fulfill()
      })
    func retry(_ id: Int64) async throws {
      let result: Result<Void, Error> = await withCheckedContinuation { continuation in
        manager.reprocessBatch(id, stepHandler: { _ in }) { continuation.resume(returning: $0) }
      }
      try result.get()
    }
    try await retry(batches[0])
    XCTAssertEqual(storage.allBatches().first { $0.id == batches[0] }?.status, "analyzed")
    XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == batches[0] && $0.card.evidenceKind == .inputInactive })
    XCTAssertFalse(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 60))).contains { $0.batchId == batches[0] })
    try await retry(batches[1])
    await fulfillment(of: [evaluated], timeout: 5)
    let cards = storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 300)))
    let idle = try XCTUnwrap(cards.first { $0.batchId == batches[1] })
    XCTAssertEqual(idle.evidenceKind, .inputInactive)
    XCTAssertEqual(idle.startTs, base)
    XCTAssertEqual(idle.endTs, base + 300)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batches[0] })
  }


  @MainActor
  func testSettingIncreasePreservesPublishedCardThenDecreasePublishesPending() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    func setThreshold(_ seconds: Int) {
      var args = original
      args[AnalysisPreferences.intervalKey] = seconds
      defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }
    setThreshold(300)
    let base = 1_801_800_000
    let path = "minimum-setting-\(UUID().uuidString)"
    let storage = StorageManager.shared
    let batches = try storage.timedWrite("setting change setup") { db -> [Int64] in
      var ids: [Int64] = []
      for (start, end) in [(0, 300), (360, 600)] {
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + start, base + end])
        ids.append(db.lastInsertedRowID)
      }
      for offset in stride(from: 0, through: 600, by: 60) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path, offset / 60])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [offset <= 300 ? ids[0] : ids[1], db.lastInsertedRowID])
      }
      return ids
    }
    defer { try? storage.timedWrite("setting change cleanup") { db in
      for id in batches {
        try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [id])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, context, _ in
      calls += 1
      let continuing = !context.existingCards.isEmpty
      if continuing {
        var raised = original
        raised[AnalysisPreferences.intervalKey] = 900
        defaults.setVolatileDomain(raised, forName: UserDefaults.argumentDomain)
      }
      let end = try XCTUnwrap(frames.last).capturedAt / 60 * 60 + 60
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(end),
        category: "Idle", subcategory: "", title: continuing ? "Continued facts" : "Old published", summary: "Synthetic", detailedSummary: continuing ? "Later detail" : "Earlier detail", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    func process(_ id: Int64) async throws -> ProcessedBatchResult {
      let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
        service.processBatch(id, progressHandler: nil) { continuation.resume(returning: $0) }
      }
      return try result.get()
    }
    let first = try await process(batches[0])
    let oldId = try XCTUnwrap(first.cardIds.first)
    // Raise the setting while the second provider request is in flight.
    let second = try await process(batches[1])
    XCTAssertTrue(second.cardIds.isEmpty)
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldId)?.title, "Old published")
    let beforePromotion = try XCTUnwrap(storage.pendingTimelineEvidence().first { $0.batchId == batches[1] && $0.endTs - $0.startTs == 600 })
    let middle = try XCTUnwrap(storage.fetchScreenshotsInTimeRange(startTs: base + 180, endTs: base + 180).first { $0.filePath == path })
    setThreshold(300)
    do {
      _ = try await LLMService.publishEligiblePending(beforePromotion, beforeCommit: {
        try? storage.timedWrite("delete promotion source before commit") { db in
          try db.execute(sql: "UPDATE screenshots SET is_deleted = 1 WHERE id = ?", arguments: [middle.id])
        }
      })
      XCTFail("A removed promotion source must abort")
    } catch TimelineCardReplacementError.sourceEvidenceChanged {
      // The deletion invalidates the pending record and the transaction publishes nothing.
    }
    XCTAssertEqual(storage.fetchTimelineCard(byId: oldId)?.title, "Old published")
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batches[1] })
    try storage.timedWrite("restore synthetic promotion source") { db in
      try db.execute(sql: "UPDATE screenshots SET is_deleted = 0 WHERE id = ?", arguments: [middle.id])
    }
    let retried = try await process(batches[1])
    XCTAssertTrue(retried.cardIds.isEmpty)
    XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == batches[1] })
    setThreshold(300)
    let evaluated = expectation(description: "decreased setting publishes once")
    let manager = AnalysisManager(store: storage, llmService: service, evaluate: { ids in
      if !ids.isEmpty { evaluated.fulfill() }
    })
    manager.triggerAnalysisNow()
    await fulfillment(of: [evaluated], timeout: 5)
    XCTAssertNil(storage.fetchTimelineCard(byId: oldId))
    let saved = try XCTUnwrap(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 600))).first { $0.title == "Continued facts" })
    XCTAssertEqual(saved.startTs, base)
    XCTAssertEqual(saved.endTs, base + 600)
    XCTAssertTrue(saved.detailedSummary.contains("Earlier detail"))
    XCTAssertTrue(saved.detailedSummary.contains("Later detail"))
    XCTAssertEqual(calls, 3)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batches[1] })
    let third = try storage.timedWrite("delete with pending setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 660, base + 720])
      let id = db.lastInsertedRowID
      for offset in [660, 720] {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path, offset / 60])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return id
    }
    defer { try? storage.timedWrite("delete with pending cleanup") { db in
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [third])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [third])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [third])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [third])
    } }
    let thirdOutput = try await process(third)
    XCTAssertTrue(thirdOutput.cardIds.isEmpty)
    let waiting = try XCTUnwrap(storage.pendingTimelineEvidence().first { $0.batchId == third })
    let savedId = try XCTUnwrap(saved.recordId)
    _ = storage.deleteTimelineCard(recordId: savedId)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == third })
    setThreshold(60)
    let deletedCannotReturn = try await LLMService.publishEligiblePending(waiting)
    XCTAssertTrue(deletedCannotReturn.isEmpty)
    XCTAssertFalse(storage.screenshotsForBatch(third).isEmpty)
  }


  @MainActor
  func testSealedSubMinuteEvidenceIsAssociatedOnceWithoutModelCall() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    let base = Int(Date().timeIntervalSince1970 - 1800) / 60 * 60
    let path = "minimum-gap-\(UUID().uuidString)"
    let offsets = [0, 30, 300, 360, 420, 480, 540, 600]
    try storage.timedWrite("short gap setup") { db in
      for (index, offset) in offsets.enumerated() {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,?)", arguments: [base + offset, path, index, offset <= 30 ? 1 : 0])
      }
    }
    defer { try? storage.timedWrite("short gap cleanup") { db in
      let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT batch_id FROM batch_screenshots WHERE screenshot_id IN (SELECT id FROM screenshots WHERE file_path = ?)", arguments: [path])
      for row in rows {
        let id: Int64 = row["batch_id"]
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, _, _ in
      calls += 1
      XCTAssertEqual(frames.first?.capturedAt, base + 300)
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base + 300), endTime: policy.formatTimestampForPrompt(base + 660), category: "Idle", subcategory: "", title: "After gap", summary: "Synthetic", detailedSummary: "Later evidence", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let evaluated = expectation(description: "later batch published")
    let manager = AnalysisManager(store: storage, llmService: service, evaluate: { ids in if !ids.isEmpty { evaluated.fulfill() } })
    manager.triggerAnalysisNow()
    await fulfillment(of: [evaluated], timeout: 5)
    let short = try XCTUnwrap(storage.allBatches().first { $0.start == base && $0.end == base + 30 })
    XCTAssertEqual(short.status, "skipped_short")
    XCTAssertEqual(storage.screenshotsForBatch(short.id).count, 2)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == short.id },
      "Sealed sub-minute black captures retain raw evidence without a generated status card")
    XCTAssertFalse(storage.fetchUnprocessedScreenshots(since: base).contains { $0.filePath == path })
    let saved = try XCTUnwrap(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 660))).first { $0.title == "After gap" })
    XCTAssertEqual(saved.startTs, base + 300)
    XCTAssertEqual(saved.endTs, base + 600)
    XCTAssertEqual(calls, 1)
    manager.triggerAnalysisNow()
    let drained = expectation(description: "timer check drained")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
    await fulfillment(of: [drained], timeout: 2)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(storage.allBatches().filter { $0.start == base && $0.end == base + 30 }.count, 1)
  }


  @MainActor
  func testMixedRedactionUsesOnePendingEventAndSourceDeletionInvalidatesIt() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let base = 1_802_400_000
    let path = "minimum-privacy-\(UUID().uuidString)"
    let storage = StorageManager.shared
    let batch = try storage.timedWrite("privacy minimum setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 240])
      let id = db.lastInsertedRowID
      for offset in stride(from: 0, through: 240, by: 60) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,?)", arguments: [base + offset, path, offset / 60, offset == 120 ? 1 : 0])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return id
    }
    defer { try? storage.timedWrite("privacy minimum cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, _, _ in
      calls += 1
      XCTAssertEqual(frames.map(\.capturedAt), [0, 60, 120, 180, 240].map { base + $0 })
      XCTAssertEqual(frames.filter(\.isPrivacyRedacted).count, 1)
      let start = try XCTUnwrap(frames.first).capturedAt / 60 * 60
      let end = try XCTUnwrap(frames.last).capturedAt / 60 * 60 + 60
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(start), endTime: policy.formatTimestampForPrompt(end), category: "Idle", subcategory: "", title: "Visible portion", summary: "Visible", detailedSummary: "Observed", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let ids = try result.get().cardIds
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(ids.isEmpty)
    let initialPending = storage.pendingTimelineEvidence().filter { $0.batchId == batch }
    XCTAssertEqual(initialPending.count, 1)
    let pending = try XCTUnwrap(initialPending.first)
    XCTAssertEqual(pending.card.evidenceKind, .visible)
    XCTAssertEqual(pending.startTs, base)
    XCTAssertEqual(pending.endTs, base + 240)
    XCTAssertEqual(Set(pending.sourceScreenshotIds), Set(storage.screenshotsForBatch(batch).map(\.id)))
    let redacted = try XCTUnwrap(storage.screenshotsForBatch(batch).first { $0.isPrivacyRedacted })
    try storage.timedWrite("delete sanitized source") { db in
      try db.execute(sql: "UPDATE screenshots SET is_deleted = 1 WHERE id = ?", arguments: [redacted.id])
    }
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
  }


  @MainActor
  func testFourAMSeparatesPendingAndPublishedEvidenceAndDeletedFramesCannotReviveIt() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let calendar = Calendar.current
    let boundary = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 5, day: 10, hour: 4)))
    let base = Int(boundary.timeIntervalSince1970) - 120
    let path = "minimum-4am-\(UUID().uuidString)"
    let storage = StorageManager.shared
    let batch = try storage.timedWrite("4am minimum setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 480])
      let id = db.lastInsertedRowID
      for offset in stride(from: 0, through: 480, by: 60) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path, offset / 60])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return id
    }
    defer { try? storage.timedWrite("4am minimum cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, _, _ in
      let start = try XCTUnwrap(frames.first).capturedAt / 60 * 60
      let end = try XCTUnwrap(frames.last).capturedAt / 60 * 60 + 60
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(start), endTime: policy.formatTimestampForPrompt(end), category: "Idle", subcategory: "", title: "Day segment", summary: "Synthetic", detailedSummary: "Evidence", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
      service.processBatch(batch, progressHandler: nil) { continuation.resume(returning: $0) }
    }
    let ids = try result.get().cardIds
    XCTAssertEqual(ids.count, 1)
    let saved = try XCTUnwrap(ids.first.flatMap { storage.fetchTimelineCard(byId: $0) })
    XCTAssertEqual(saved.startTs, base + 120)
    XCTAssertEqual(saved.endTs, base + 480)
    let pending = try XCTUnwrap(storage.pendingTimelineEvidence().first { $0.batchId == batch })
    XCTAssertEqual(pending.startTs, base)
    XCTAssertEqual(pending.endTs, base + 60)
    storage.markScreenshotsDeleted(segmentPath: path)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
    args[AnalysisPreferences.intervalKey] = 60
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    let afterDeletion = try await LLMService.publishEligiblePending(pending)
    XCTAssertTrue(afterDeletion.isEmpty)
  }


  @MainActor
  func testRecordedStopSplitsAnalysisEvenWhenCaptureGapIsShort() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    var base = (Int(Date().timeIntervalSince1970) + 6 * 3600) / 60 * 60
    if Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      != Date(timeIntervalSince1970: Double(base + 420)).getDayInfoFor4AMBoundary().dayString { base += 3600 }
    TimelineCaptureBoundaries.shared.recordStop(at: base + 30)
    let path = "minimum-stop-\(UUID().uuidString)"
    let storage = StorageManager.shared
    try storage.timedWrite("stop minimum setup") { db in
      for offset in stride(from: 0, through: 360, by: 60) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path, offset / 60])
      }
    }
    defer { try? storage.timedWrite("stop minimum cleanup") { db in
      let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT batch_id FROM batch_screenshots WHERE screenshot_id IN (SELECT id FROM screenshots WHERE file_path = ?)", arguments: [path])
      for row in rows {
        let id: Int64 = row["batch_id"]
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, _, _ in
      calls += 1
      XCTAssertEqual(frames.first?.capturedAt, base + 60)
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base + 60), endTime: policy.formatTimestampForPrompt(base + 420), category: "Idle", subcategory: "", title: "After stop", summary: "Synthetic", detailedSummary: "Later evidence", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let evaluated = expectation(description: "only post-stop event evaluated")
    let manager = AnalysisManager(store: storage, llmService: service, evaluate: { ids in if !ids.isEmpty { evaluated.fulfill() } })
    manager.triggerAnalysisNow()
    await fulfillment(of: [evaluated], timeout: 5)
    let short = try XCTUnwrap(storage.allBatches().first { $0.start == base && $0.end == base })
    XCTAssertEqual(short.status, "skipped_short")
    let card = try XCTUnwrap(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 420))).first { $0.title == "After stop" })
    XCTAssertEqual(card.startTs, base + 60)
    XCTAssertEqual(card.endTs, base + 360)
    XCTAssertEqual(calls, 1)
  }


  @MainActor
  func testPendingDoesNotContinueAcrossKnownCurrentSessionStart() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    func threshold(_ seconds: Int) {
      var args = original
      args[AnalysisPreferences.intervalKey] = seconds
      defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }
    threshold(900)
    let base = Int(Date().timeIntervalSince1970) / 60 * 60 - 660
    guard Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      == Date(timeIntervalSince1970: Double(base + 1020)).getDayInfoFor4AMBoundary().dayString else {
      throw XCTSkip("The fixture overlaps the independent 4 AM boundary")
    }
    let storage = StorageManager.shared
    let path = "minimum-session-\(UUID().uuidString)"
    let ids = try storage.timedWrite("session boundary setup") { db -> [Int64] in
      var batches: [Int64] = []
      for (start, end) in [(0, 600), (720, 1020)] {
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + start, base + end])
        batches.append(db.lastInsertedRowID)
      }
      for offset in Array(stride(from: 0, through: 600, by: 60)) + Array(stride(from: 720, through: 1020, by: 60)) {
        let earlier = offset <= 600
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path + (earlier ? "-old" : "-new"), earlier ? offset / 60 : (offset - 720) / 60])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [earlier ? batches[0] : batches[1], db.lastInsertedRowID])
      }
      return batches
    }
    defer { try? storage.timedWrite("session boundary cleanup") { db in
      for id in ids {
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path IN (?,?)", arguments: [path + "-old", path + "-new"])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, context, _ in
      calls += 1
      XCTAssertTrue(context.existingCards.isEmpty)
      let start = try XCTUnwrap(frames.first).capturedAt / 60 * 60
      let end = try XCTUnwrap(frames.last).capturedAt / 60 * 60 + 60
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(start), endTime: policy.formatTimestampForPrompt(end), category: "Idle", subcategory: "", title: "Session segment", summary: "Synthetic", detailedSummary: "Evidence", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    func process(_ id: Int64) async throws -> ProcessedBatchResult {
      let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
        service.processBatch(id, progressHandler: nil) { continuation.resume(returning: $0) }
      }
      return try result.get()
    }
    let old = try await process(ids[0])
    XCTAssertTrue(old.cardIds.isEmpty)
    XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == ids[0] })
    threshold(300)
    let fresh = try await process(ids[1])
    let card = try XCTUnwrap(fresh.cardIds.first.flatMap { storage.fetchTimelineCard(byId: $0) })
    XCTAssertEqual(card.startTs, base + 720)
    XCTAssertEqual(card.endTs, base + 1020)
    XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == ids[0] })
    XCTAssertEqual(calls, 2)
  }


  @MainActor
  func testDeletingModelInputWhileProviderIsRunningAbortsWithoutPublication() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let storage = StorageManager.shared
    var base = (Int(Date().timeIntervalSince1970) + 1200) / 60 * 60
    if Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      != Date(timeIntervalSince1970: Double(base + 360)).getDayInfoFor4AMBoundary().dayString { base += 3600 }
    let path = "minimum-model-race-\(UUID().uuidString)"
    let batch = try storage.timedWrite("provider deletion setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 300])
      let id = db.lastInsertedRowID
      for offset in stride(from: 0, through: 300, by: 60) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,0)", arguments: [base + offset, path, offset / 60])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return id
    }
    defer { try? storage.timedWrite("provider deletion cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let middle = try XCTUnwrap(storage.screenshotsForBatch(batch).first { $0.capturedAt == base + 120 })
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, _, _ in
      XCTAssertTrue(frames.contains { $0.id == middle.id })
      await Task.yield()
      try storage.timedWrite("delete source while model awaits") { db in
        try db.execute(sql: "UPDATE screenshots SET is_deleted = 1 WHERE id = ?", arguments: [middle.id])
      }
      await Task.yield()
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(base + 360), category: "Idle", subcategory: "", title: "Stale model output", summary: "Synthetic", detailedSummary: "Deleted input", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    var notifications = 0
    var evaluated = false
    let observer = NotificationCenter.default.addObserver(forName: .timelineCardsDidCommit, object: nil, queue: nil) { _ in notifications += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    let manager = AnalysisManager(store: storage, llmService: service, evaluate: { _ in evaluated = true })
    let result: Result<Void, Error> = await withCheckedContinuation { continuation in
      manager.reprocessBatch(batch, stepHandler: { _ in }) { continuation.resume(returning: $0) }
    }
    guard case .failure(let error) = result else { XCTFail("Deleted input must abort"); return }
    guard case TimelineCardReplacementError.sourceEvidenceChanged = error else { XCTFail("Unexpected error: \(error)"); return }
    XCTAssertEqual(notifications, 0)
    XCTAssertFalse(evaluated)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
    XCTAssertFalse(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 360))).contains { $0.batchId == batch })
  }


  @MainActor
  func testBlackOnlyPendingContinuesToMinimumAndRewritesThroughConfiguredProvider() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let now = Int(Date().timeIntervalSince1970)
    var base = (now - 1800) / 60 * 60
    if Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      != Date(timeIntervalSince1970: Double(base + 600)).getDayInfoFor4AMBoundary().dayString { base -= 3600 }
    let path = "minimum-private-continuation-\(UUID().uuidString)"
    let storage = StorageManager.shared
    func insert(_ offsets: [Int]) throws -> Int64 {
      try storage.timedWrite("privacy continuation setup") { db in
        try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)",
          arguments: [base + offsets.first!, base + offsets.last!])
        let batch = db.lastInsertedRowID
        for offset in offsets {
          try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,idle_seconds_at_capture,is_privacy_redacted) VALUES (?,?,?,?,1)", arguments: [base + offset, path, offset / 60, 0])
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [batch, db.lastInsertedRowID])
        }
        return batch
      }
    }
    defer { try? storage.timedWrite("privacy continuation cleanup") { db in
      let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT batch_id FROM batch_screenshots WHERE screenshot_id IN (SELECT id FROM screenshots WHERE file_path = ?)", arguments: [path])
      for row in rows {
        let id: Int64 = row["batch_id"]
        try db.execute(sql: "DELETE FROM target_assessments WHERE card_id IN (SELECT id FROM timeline_cards WHERE batch_id = ?)", arguments: [id])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
      }
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    var calls = 0
    let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, context, _ in
      calls += 1
      XCTAssertTrue(frames.allSatisfy(\.isPrivacyRedacted))
      if calls > 1 {
        XCTAssertEqual(context.existingCards.count, 1)
        XCTAssertTrue(context.hasContinuousCaptureBeforeBatch)
      }
      let end = try XCTUnwrap(frames.last).capturedAt / 60 * 60 + 60
      let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(base), endTime: policy.formatTimestampForPrompt(end), category: "Idle", subcategory: "", title: "Black frames", summary: "Activity unavailable in redacted captures", detailedSummary: "No hidden activity inferred", distractions: nil, appSites: nil)
      return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    })
    let suite = "PrivacyMinimumEvaluation.\(UUID().uuidString)"
    let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { targetDefaults.removePersistentDomain(forName: suite) }
    let event = TimelineCategory(name: "Synthetic target", colorHex: "#000000", order: 0, targetEnabled: true)
    let target = FocusTarget(id: UUID(), text: event.name, startedAt: Date(timeIntervalSince1970: Double(base - 60)),
      events: [FocusTargetEvent(id: event.id, name: event.name, details: event.details)])
    targetDefaults.set(try JSONEncoder().encode(target), forKey: "target.current")
    let targetStore = TargetStore(defaults: targetDefaults, storage: storage,
      automaticReminders: AutomaticReminderState(isRecording: false), notify: { _, _, _ in false }, generate: { _ in
        XCTFail("Black-frame event alignment must also be local")
        return "invalid"
      })
    targetStore.synchronize(events: [event])
    let firstDone = expectation(description: "short model event stays pending")
    let published = expectation(description: "qualified model event evaluated")
    let extended = expectation(description: "continuous model rewrite evaluated")
    var publishedIDs: [Int64] = []
    var publicationCount = 0
    let manager = AnalysisManager(store: storage, llmService: service, evaluate: { ids in
      if ids.isEmpty { firstDone.fulfill() }
      else {
        publishedIDs = ids
        targetStore.enqueue(cardIDs: ids)
        publicationCount += 1
        if publicationCount == 1 { published.fulfill() } else { extended.fulfill() }
      }
    })
    func process(_ batch: Int64) async throws {
      let result: Result<Void, Error> = await withCheckedContinuation { continuation in
        manager.reprocessBatch(batch, stepHandler: { _ in }) { continuation.resume(returning: $0) }
      }
      try result.get()
    }
    let firstBatch = try insert([0, 60])
    try await process(firstBatch)
    await fulfillment(of: [firstDone], timeout: 5)
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(targetStore.assessments.isEmpty)
    let pending = try XCTUnwrap(storage.pendingTimelineEvidence().first { $0.batchId == firstBatch })
    XCTAssertEqual(pending.card.evidenceKind, .visible)
    XCTAssertEqual(pending.endTs - pending.startTs, 60)
    XCTAssertTrue(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 300))).isEmpty)
    let secondBatch = try insert([120, 180, 240, 300])
    try await process(secondBatch)
    await fulfillment(of: [published], timeout: 5)
    await targetStore.waitForEvaluations()
    let id = try XCTUnwrap(publishedIDs.first)
    let card = try XCTUnwrap(storage.fetchTimelineCard(byId: id))
    XCTAssertEqual(card.evidenceKind, .visible)
    XCTAssertEqual(card.startTs, base)
    XCTAssertEqual(card.endTs, base + 300)
    XCTAssertEqual(targetStore.assessments[id]?.alignment, .severe)
    XCTAssertEqual(targetStore.assessments[id]?.targetText, event.name)
    XCTAssertFalse(targetStore.assessments[id]?.reminder.isEmpty ?? true)
    XCTAssertEqual(calls, 2)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == firstBatch })
    let thirdBatch = try insert([360, 420, 480, 540, 600])
    try await process(thirdBatch)
    await fulfillment(of: [extended], timeout: 5)
    await targetStore.waitForEvaluations()
    let extendedID = try XCTUnwrap(publishedIDs.first)
    let extendedCard = try XCTUnwrap(storage.fetchTimelineCard(byId: extendedID))
    XCTAssertNil(storage.fetchTimelineCard(byId: id))
    XCTAssertEqual(extendedCard.startTs, base)
    XCTAssertEqual(extendedCard.endTs, base + 600)
    XCTAssertEqual(extendedCard.evidenceKind, .visible)
    XCTAssertEqual(targetStore.assessments[extendedID]?.alignment, .severe)
    XCTAssertEqual(calls, 3)
  }


  @MainActor
  func testBlackCapturesUseProviderButNeverContinueAcrossStopOrFourAM() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let calendar = Calendar.current
    let boundary = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 7, day: 10, hour: 4)))
    let storage = StorageManager.shared
    let connection = AIProviderConnection(name: "Stub", kind: .local, models: [AIConfiguredModel(id: "test")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "test")
    let config = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let policy = TimelineOutputPolicy()
    for (mode, base) in [("stop", 1_804_000_020), ("4am", Int(boundary.timeIntervalSince1970) - 120)] {
      let path = "minimum-private-boundary-\(mode)-\(UUID().uuidString)"
      if mode == "stop" { TimelineCaptureBoundaries.shared.recordStop(at: base + 90) }
      let ids = try storage.timedWrite("privacy boundary setup") { db -> [Int64] in
        var batches: [Int64] = []
        for (start, end) in [(0, 60), (120, 420)] {
          try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + start, base + end])
          batches.append(db.lastInsertedRowID)
        }
        for offset in stride(from: 0, through: 420, by: 60) {
          try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,1)", arguments: [base + offset, path, offset / 60])
          try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [offset <= 60 ? batches[0] : batches[1], db.lastInsertedRowID])
        }
        return batches
      }
      defer { try? storage.timedWrite("privacy boundary cleanup") { db in
        for id in ids {
          try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [id])
          try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [id])
          try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [id])
          try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
      } }
      var calls = 0
      let service = LLMService(loadConfiguration: { config }, timelineGeneratorOverride: { frames, context, _ in
        calls += 1
        XCTAssertTrue(frames.allSatisfy(\.isPrivacyRedacted))
        XCTAssertTrue(context.existingCards.isEmpty, mode)
        let start = try XCTUnwrap(frames.first).capturedAt
        let end = try XCTUnwrap(frames.last).capturedAt / 60 * 60 + 60
        let card = ActivityCardData(startTime: policy.formatTimestampForPrompt(start),
          endTime: policy.formatTimestampForPrompt(end), category: "Idle", subcategory: "",
          title: "Redacted captures", summary: "Activity unavailable", detailedSummary: "No hidden activity inferred",
          distractions: nil, appSites: nil)
        return ([card], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
      })
      func process(_ id: Int64) async throws -> ProcessedBatchResult {
        let result: Result<ProcessedBatchResult, Error> = await withCheckedContinuation { continuation in
          service.processBatch(id, progressHandler: nil) { continuation.resume(returning: $0) }
        }
        return try result.get()
      }
      let first = try await process(ids[0])
      XCTAssertTrue(first.cardIds.isEmpty, mode)
      XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == ids[0] && $0.card.evidenceKind == .visible }, mode)
      let second = try await process(ids[1])
      let card = try XCTUnwrap(second.cardIds.first.flatMap { storage.fetchTimelineCard(byId: $0) })
      XCTAssertEqual(card.startTs, base + 120, mode)
      XCTAssertEqual(card.endTs, base + 420, mode)
      XCTAssertEqual(card.evidenceKind, .visible, mode)
      XCTAssertEqual(calls, 2, mode)
      XCTAssertTrue(storage.pendingTimelineEvidence().contains { $0.batchId == ids[0] }, mode)
    }
  }


  @MainActor
  func testBlackOnlyProviderSetupFailureReportsOrdinaryErrorWithoutPrivacyPublication() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let defaults = AppStoragePaths.defaults
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var args = original
    args[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    var base = (Int(Date().timeIntervalSince1970) + 3600) / 60 * 60
    if Date(timeIntervalSince1970: Double(base)).getDayInfoFor4AMBoundary().dayString
      != Date(timeIntervalSince1970: Double(base + 480)).getDayInfoFor4AMBoundary().dayString { base += 3600 }
    let path = "minimum-failed-visible-\(UUID().uuidString)"
    let storage = StorageManager.shared
    let batch = try storage.timedWrite("failed visible privacy setup") { db -> Int64 in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 420])
      let id = db.lastInsertedRowID
      for offset in stride(from: 0, through: 420, by: 60) {
        try db.execute(sql: "INSERT INTO screenshots(captured_at,file_path,frame_index,is_privacy_redacted) VALUES (?,?,?,?)", arguments: [base + offset, path, offset / 60, 1])
        try db.execute(sql: "INSERT INTO batch_screenshots(batch_id,screenshot_id) VALUES (?,?)", arguments: [id, db.lastInsertedRowID])
      }
      return id
    }
    defer { try? storage.timedWrite("failed visible privacy cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM batch_screenshots WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM screenshots WHERE file_path = ?", arguments: [path])
    } }
    let service = LLMService(loadConfiguration: { throw AIConfiguredRuntimeError.missingRoute })
    var evaluatedIDs: [Int64] = []
    let manager = AnalysisManager(store: storage, llmService: service, evaluate: { ids in
      evaluatedIDs.append(contentsOf: ids)
    })
    let result: Result<Void, Error> = await withCheckedContinuation { continuation in
      manager.reprocessBatch(batch, stepHandler: { _ in }) { continuation.resume(returning: $0) }
    }
    guard case .failure(let error) = result else { XCTFail("Black captures require the configured provider"); return }
    guard case AIConfiguredRuntimeError.missingRoute = error else { XCTFail("Unexpected error: \(error)"); return }
    XCTAssertTrue(evaluatedIDs.isEmpty)
    XCTAssertFalse(storage.pendingTimelineEvidence().contains { $0.batchId == batch })
    let cards = storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(base)), to: Date(timeIntervalSince1970: Double(base + 480))).filter { $0.batchId == batch }
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards.first?.category, "System")
    XCTAssertEqual(cards.first?.title, "Processing failed")
    XCTAssertFalse(cards.contains { $0.evidenceKind == .privacyRedacted })
  }

}
