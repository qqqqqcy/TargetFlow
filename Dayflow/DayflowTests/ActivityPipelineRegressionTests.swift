import Foundation
import GRDB
import XCTest

@testable import Dayflow

final class ActivityPipelineRegressionTests: XCTestCase {
  private func sample(_ second: Int, privacy: Bool = false, idle: Int? = nil) -> Screenshot {
    Screenshot(id: Int64(second + 1), capturedAt: second, filePath: "synthetic", fileSize: nil,
      idleSecondsAtCapture: idle ?? second, isDeleted: false, isPrivacyRedacted: privacy)
  }

  func testStaticEvidenceIgnoresPrivacyFlagButRequiresMatchingPixelsAndInput() {
    let history = stride(from: 0, through: 900, by: 30).map { sample($0) }
    let batch = stride(from: 900, through: 1200, by: 30).map { sample($0) }
    let pixels: (Screenshot) -> [UInt8]? = { _ in Array(repeating: 32, count: 128) }
    XCTAssertNotNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: 900, pixels: pixels))
    XCTAssertNil(IdleBatchClassifier.assess(Array(batch.prefix(5)), thresholdSeconds: 900, pixels: pixels))
    let withPrivacy = history.map { $0.capturedAt == 450 ? sample(450, privacy: true) : $0 }
    XCTAssertNotNil(IdleBatchClassifier.assess(batch, history: withPrivacy, thresholdSeconds: 900, pixels: pixels))
    XCTAssertNil(IdleBatchClassifier.assess(batch, history: withPrivacy, thresholdSeconds: 900, pixels: {
      $0.isPrivacyRedacted ? Array(repeating: 0, count: 128) : pixels($0)
    }))
    XCTAssertNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: 900, pixels: {
      $0.capturedAt == 450 ? nil : pixels($0)
    }))
    let changed = history.map { $0.capturedAt == 450 ? sample(450, idle: 0) : $0 }
    XCTAssertNil(IdleBatchClassifier.assess(batch, history: changed, thresholdSeconds: 900, pixels: pixels))
  }

  func testStaticThresholdAcrossFiveMinuteBatchesAndDenseSampling() {
    let pixels: (Screenshot) -> [UInt8]? = { _ in Array(repeating: 40, count: 128) }
    for step in [1, 30] {
      let history = stride(from: 0, through: 600, by: step).map { sample($0) }
      let batch = stride(from: 600, through: 900, by: step).map { sample($0) }
      XCTAssertNotNil(IdleBatchClassifier.assess(batch, history: history, thresholdSeconds: 900, pixels: pixels), "cadence \(step)")
      let gap = history.filter { !((240...420).contains($0.capturedAt)) }
      XCTAssertNil(IdleBatchClassifier.assess(batch, history: gap, thresholdSeconds: 900, pixels: pixels), "gap \(step)")
    }
  }

  func testMissingCaptureMinuteLeavesGapBetweenEvidenceSpans() {
    let spans = TimelineEvidencePolicy.partition([sample(0), sample(120)])
    XCTAssertEqual(spans.count, 2)
    XCTAssertEqual(spans[0].startTs, 0)
    XCTAssertEqual(spans[0].endTs, 60)
    XCTAssertEqual(spans[1].startTs, 120)
    XCTAssertEqual(spans[1].endTs, 180)
  }

  func testReplacementGroupsDoNotSpanCaptureGap() throws {
    func card(_ start: String, _ end: String) -> ActivityCardData {
      ActivityCardData(startTime: start, endTime: end, category: "__unmatched__", subcategory: "",
        title: "Synthetic", summary: "", detailedSummary: "", distractions: nil, appSites: nil)
    }
    let groups = try TimelineEvidencePolicy.replacementGroups(
      [card("10:00 AM", "10:01 AM"), card("10:01 AM", "10:02 AM"),
       card("10:04 AM", "10:05 AM")], nearest: 1_800_000_000)
    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups.map { $0.range.count }, [120, 60])
    XCTAssertEqual(groups[1].range.lowerBound - groups[0].range.upperBound, 120)
  }

  func testUnknownCategoriesDoNotBecomeConfiguredEvents() {
    let item = TimelineCategory(name: "Synthetic A", colorHex: "#000000", order: 0)
    let descriptor = LLMCategoryDescriptor(id: item.id, name: item.name, colorHex: item.colorHex,
      description: nil, isSystem: false, isIdle: false)
    let policy = TimelineOutputPolicy()
    XCTAssertEqual(policy.normalizeCategory("Synthetic A", descriptors: [descriptor]), "Synthetic A")
    XCTAssertEqual(policy.normalizeCategory("Synthetic C", descriptors: [descriptor]), "Idle")
    XCTAssertEqual(policy.normalizeCategory("", descriptors: [descriptor]), "Idle")
    XCTAssertEqual(policy.normalizeCategory("__unmatched__", descriptors: [descriptor]), "Idle")
    XCTAssertEqual(policy.normalizeCategory("Synthetic C", descriptors: []), "Idle")
    XCTAssertTrue(TimelineEventDisplay.reservedCategory("__unmatched__")?.isIdle == true)
    let normalized = policy.normalizeCards([ActivityCardData(startTime: "10:00 AM", endTime: "10:05 AM",
      category: "__unmatched__", subcategory: "", title: "Actual activity", summary: "Actual purpose",
      detailedSummary: "Concrete details", distractions: nil, appSites: nil, evidenceKind: .visible)],
      descriptors: [descriptor])
    XCTAssertEqual(normalized.first?.category, "Idle")
    XCTAssertEqual(normalized.first?.title, "Actual activity")
    XCTAssertEqual(normalized.first?.detailedSummary, "Concrete details")
    XCTAssertEqual(normalized.first?.evidenceKind, .visible)
    XCTAssertEqual(TimelineEventDisplay.reservedCategory("__privacy__")?.isIdle, true)
    let protected = policy.normalizeCards([
      TimelineEvidencePolicy.privacyCard(start: "10:00 AM", end: "10:05 AM"),
      ActivityCardData(startTime: "10:05 AM", endTime: "10:10 AM",
        category: "Synthetic A", subcategory: "", title: "privacy placeholder",
        summary: "Content hidden by privacy settings", detailedSummary: "",
        distractions: nil, appSites: nil)
    ], descriptors: [descriptor])
    XCTAssertEqual(protected.map(\.category), ["Idle", "Synthetic A"])
    XCTAssertEqual(protected[0].evidenceKind, .privacyRedacted, "Explicit legacy metadata remains readable")
    XCTAssertNil(protected[1].evidenceKind, "Model prose must not manufacture privacy metadata")
    XCTAssertEqual(protected[1].title, "privacy placeholder")
    XCTAssertEqual(protected[1].summary, "Content hidden by privacy settings")
    XCTAssertTrue(protected.allSatisfy { $0.appSites == nil && $0.detailedSummary.isEmpty })
  }

  func testStaleAssessmentCannotOverwriteChangedEvidenceCategoryOrDistractions() throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let id: Int64 = try storage.db.write { db in
      try db.execute(sql: """
        INSERT INTO timeline_cards(start, end, start_ts, end_ts, day, title, category, summary, detailed_summary, metadata)
        VALUES ('10:00 AM', '10:05 AM', 4000000000, 4000000300, '2096-10-02', 'Synthetic', 'A', '', '', '{}')
        """)
      return db.lastInsertedRowID
    }
    defer { try? storage.db.write { db in
      try db.execute(sql: "DELETE FROM target_assessments WHERE card_id = ?", arguments: [id])
      try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ?", arguments: [id])
    } }
    let old = try XCTUnwrap(storage.fetchTimelineCard(byId: id))
    let assessment = TargetAssessment(cardID: id, targetID: UUID(), targetText: "Synthetic goal",
      cardTitle: old.title, fingerprint: TargetStore.fingerprint(old),
      startTime: Date(timeIntervalSince1970: Double(old.startTs)),
      endTime: Date(timeIntervalSince1970: Double(old.endTs)),
      alignment: .focused, reason: "Synthetic", reminder: "")
    XCTAssertTrue(try storage.saveTargetAssessment(assessment, card: old))
    for (category, metadata) in [
      ("B", "{}"),
      ("A", #"{"evidenceKind":"privacyRedacted"}"#),
      ("A", #"{"distractions":[{"id":"00000000-0000-0000-0000-000000000001","startTime":"10:01 AM","endTime":"10:02 AM","title":"Synthetic B","summary":""}]}"#),
    ] {
      try storage.db.write { db in
        try db.execute(sql: "UPDATE timeline_cards SET category = ?, metadata = ? WHERE id = ?", arguments: [category, metadata, id])
      }
      XCTAssertFalse(try storage.saveTargetAssessment(assessment, card: old))
    }
    try storage.db.write { db in
      try db.execute(sql: "UPDATE timeline_cards SET category = ?, metadata = ? WHERE id = ?",
        arguments: ["A", #"{"distractions":[{"startTime":"10:01 AM","endTime":"10:02 AM","title":"Synthetic B","summary":""}]}"#, id])
    }
    let legacy = try XCTUnwrap(storage.fetchTimelineCard(byId: id))
    XCTAssertTrue(try storage.saveTargetAssessment(assessment, card: legacy))
  }

  @MainActor
  func testPersistedFocusedThenUnmatchedEventAndPrivacyAreEvaluatedSeparately() async throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let now = Int(Date().timeIntervalSince1970)
    let entries: [(String, String, Int, Int, String)] = [
      ("Synthetic A", "Synthetic A", now - 600, now - 300, #"{"evidenceKind":"visible"}"#),
      ("Synthetic B", "__unmatched__", now - 300, now - 120, #"{"evidenceKind":"visible"}"#),
      ("Private interval", "__privacy__", now - 120, now - 60, #"{"evidenceKind":"privacyRedacted"}"#),
    ]
    let ids: [Int64] = try storage.timedWrite("regression setup") { db in
      var result: [Int64] = []
      for (title, category, start, end, metadata) in entries {
        try db.execute(sql: """
          INSERT INTO timeline_cards(start, end, start_ts, end_ts, day, title, category, summary, detailed_summary, metadata)
          VALUES ('10:00 AM', '10:05 AM', ?, ?, '2096-10-02', ?, ?, '', '', ?)
          """, arguments: [start, end, title, category, metadata])
        result.append(db.lastInsertedRowID)
      }
      return result
    }
    defer { try? storage.timedWrite("regression cleanup") { db in
      for id in ids {
        try db.execute(sql: "DELETE FROM target_assessments WHERE card_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM timeline_cards WHERE id = ?", arguments: [id])
      }
    } }
    let suite = "ActivityPipelineRegression.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: TargetPreferences.alertsEnabledKey)
    let event = TimelineCategory(name: "Synthetic A", colorHex: "#000000", order: 0, targetEnabled: true)
    let target = FocusTarget(id: UUID(), text: event.name, startedAt: Date(timeIntervalSince1970: Double(now - 900)),
      events: [FocusTargetEvent(id: event.id, name: event.name, details: event.details)])
    defaults.set(try JSONEncoder().encode(target), forKey: "target.current")
    var reminders = 0
    let targetStore = TargetStore(defaults: defaults, storage: storage,
      automaticReminders: AutomaticReminderState(isRecording: true),
      notify: { _, _, allowed in if allowed() { reminders += 1; return true }; return false },
      generate: { _ in
        XCTFail("All event alignment, including privacy, must be local")
        return "invalid"
      })
    targetStore.synchronize(events: [event])
    targetStore.enqueue(cardIDs: ids)
    await targetStore.waitForEvaluations()
    XCTAssertEqual(Set(storage.fetchTimelineCardsByTimeRange(from: Date(timeIntervalSince1970: Double(now - 601)), to: Date(timeIntervalSince1970: Double(now))).map(\.recordId).compactMap { $0 }).intersection(Set(ids)), Set(ids))
    XCTAssertEqual(targetStore.assessments[ids[0]]?.alignment, .focused)
    XCTAssertEqual(targetStore.assessments[ids[1]]?.alignment, .severe)
    XCTAssertEqual(targetStore.assessments[ids[2]]?.alignment, .severe)
    XCTAssertEqual(reminders, 2)
    let saved = try storage.fetchTargetAssessments().filter { ids.contains($0.cardID) }
    XCTAssertEqual(Set(saved.map(\.cardID)), Set(ids))
  }


  func testVisibleBlackVisiblePersistsOneModelCardWithAllSupportedCaptures() async throws {
    let base = 1_800_000_000
    let formatter = TimelineOutputPolicy()
    let frames = (0..<6).map { minute in
      Screenshot(id: Int64(minute), capturedAt: base + minute * 60, filePath: "synthetic", fileSize: nil,
        idleSecondsAtCapture: 0, isDeleted: false, isPrivacyRedacted: minute == 2 || minute == 3)
    }
    let context = ActivityGenerationContext(batchObservations: [], existingCards: [],
      currentTime: Date(timeIntervalSince1970: Double(base + 360)), categories: [],
      hasPreviousCardWithinFiveMinutes: false)
    var calls = 0
    let result = try await TimelineEvidencePolicy.generate(screenshots: frames, context: context, batchId: 1) {
      shots, _, _ in
      calls += 1
      XCTAssertEqual(shots.map(\.id), frames.map(\.id))
      XCTAssertEqual(shots.filter(\.isPrivacyRedacted).count, 2)
      let start = shots[0].capturedAt
      let end = shots.last!.capturedAt + 60
      let distractions: [Distraction]? = nil
      let card = ActivityCardData(startTime: formatter.formatTimestampForPrompt(start),
        endTime: formatter.formatTimestampForPrompt(end), category: "unrelated", subcategory: "",
        title: "Synthetic A", summary: "Visible work around black frames; hidden activity unavailable",
        detailedSummary: "\(formatter.formatTimestampForPrompt(start)) - \(formatter.formatTimestampForPrompt(start + 120)): A ONLY\n\(formatter.formatTimestampForPrompt(start + 240)) - \(formatter.formatTimestampForPrompt(end)): B ONLY",
        distractions: distractions,
        appSites: nil)
      return ([card], [], start..<end, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
    }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(result.cards.count, 1)
    XCTAssertEqual(result.cards.map(\.evidenceKind), [.visible])
    XCTAssertEqual(result.cards[0].title, "Synthetic A")
    XCTAssertEqual(result.cards[0].summary, "Visible work around black frames; hidden activity unavailable")
    XCTAssertTrue(result.cards[0].detailedSummary.contains("A ONLY"))
    XCTAssertTrue(result.cards[0].detailedSummary.contains("B ONLY"))
    XCTAssertEqual(result.cards[0].category, "Idle")
    XCTAssertEqual(result.cards[0].startTime, formatter.formatTimestampForPrompt(base))
    XCTAssertEqual(result.cards[0].endTime, formatter.formatTimestampForPrompt(base + 360))
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let batch: Int64 = try storage.timedWrite("provider regression setup") { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts) VALUES (?, ?)", arguments: [base, base + 360])
      return db.lastInsertedRowID
    }
    defer { try? storage.timedWrite("provider regression cleanup") { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let shells = result.cards.map { card in TimelineCardShell(
      startTimestamp: card.startTime, endTimestamp: card.endTime, category: card.category,
      subcategory: card.subcategory, title: card.title, summary: card.summary,
      detailedSummary: card.detailedSummary, distractions: card.distractions, appSites: card.appSites,
      evidenceKind: card.evidenceKind) }
    let saved = storage.replaceTimelineCardsInRange(from: Date(timeIntervalSince1970: Double(base)),
      to: Date(timeIntervalSince1970: Double(base + 360)), with: shells, batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil)
    XCTAssertEqual(saved.insertedIds.count, 1)
    let stored = saved.insertedIds.compactMap { storage.fetchTimelineCard(byId: $0) }
    XCTAssertEqual(stored.map(\.evidenceKind), [.visible])
    XCTAssertEqual(stored[0].summary, result.cards[0].summary)
    XCTAssertTrue(stored[0].detailedSummary.contains("B ONLY"))
  }


  func testSanitizedHistoricalBoundariesAreReplayedWithoutInventingPrivacyContent() throws {
    // Redacted intervals copied from local cards 27, 96, 235; no private titles or media.
    let cases: [(Int, String, String, [(String, String)])] = [
      (27, "7:13 PM", "7:18 PM", [("7:14 PM", "7:15 PM"), ("7:15 PM", "7:16 PM"), ("7:17 PM", "7:18 PM")]),
      (96, "5:00 PM", "6:00 PM", [("5:02 PM", "5:03 PM"), ("5:05 PM", "5:06 PM"),
        ("5:09 PM", "5:11 PM"), ("5:19 PM", "5:23 PM"), ("5:23 PM", "5:26 PM"),
        ("5:28 PM", "5:29 PM"), ("5:29 PM", "5:30 PM"), ("5:35 PM", "5:36 PM"),
        ("5:37 PM", "5:38 PM"), ("5:39 PM", "5:41 PM"), ("5:41 PM", "5:44 PM"),
        ("5:44 PM", "5:47 PM"), ("5:49 PM", "5:52 PM")]),
      (235, "5:04 PM", "6:01 PM", [("5:56 PM", "5:58 PM")]),
    ]
    for (id, start, end, intervals) in cases {
      let distractions = intervals.enumerated().map { index, interval in
        Distraction(startTime: interval.0, endTime: interval.1,
          title: id == 27 && index == 0 ? "privacy placeholder" : "Synthetic activity",
          summary: id == 27 && index == 0 ? "Content hidden by privacy settings" : "Synthetic description")
      }
      let input = ActivityCardData(startTime: start, endTime: end, category: "Synthetic A",
        subcategory: "", title: "Synthetic A", summary: "", detailedSummary: "",
        distractions: distractions, appSites: nil)
      let pieces = TimelineEvidencePolicy.splitDistractions([input], nearest: 1_793_000_000)
      XCTAssertGreaterThan(pieces.count, 1, "card \(id)")
      XCTAssertFalse(pieces.contains { !($0.distractions ?? []).isEmpty }, "card \(id)")
      if id == 27 {
        let hidden = try XCTUnwrap(pieces.first { $0.startTime == "7:14 PM" })
        XCTAssertNil(hidden.evidenceKind)
        XCTAssertEqual(hidden.title, "privacy placeholder")
        XCTAssertEqual(hidden.summary, "Content hidden by privacy settings")
      }
      print("Sanitized replay card=\(id), input_intervals=\(intervals.count), output_cards=\(pieces.count)")
    }
  }


  func testReservedLabelsAreReadableAndVisibleOtherDoesNotBecomeGoalTotals() {
    func card(_ category: String, _ start: String, _ end: String, evidence: ActivityEvidenceKind) -> TimelineCard {
      TimelineCard(recordId: nil, batchId: nil, startTimestamp: start, endTimestamp: end,
        category: category, subcategory: "", title: "Synthetic", summary: "", detailedSummary: "",
        day: "2026-10-30", distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil,
        appSites: nil, evidenceKind: evidence)
    }
    let cards = [card("__unmatched__", "10:00 AM", "10:05 AM", evidence: .visible),
      card("__privacy__", "10:05 AM", "10:10 AM", evidence: .privacyRedacted)]
    let export = TimelineClipboardFormatter.makeClipboardText(for: Date(), cards: cards)
    XCTAssertFalse(export.contains("__unmatched__"))
    XCTAssertFalse(export.contains("__privacy__"))
    let precomputed = DaySummaryStats.precomputeCardDurations(cards)
    let snapshots = [DayGoalCategorySnapshot(categoryID: "0", name: "__unmatched__", colorHex: "#000000", sortOrder: 0),
      DayGoalCategorySnapshot(categoryID: "1", name: "__privacy__", colorHex: "#000000", sortOrder: 1)]
    XCTAssertEqual(DaySummaryStats.computeTotalFocusTime(from: precomputed, snapshots: snapshots, categories: []), 0)
    XCTAssertEqual(DaySummaryStats.computeTotalDistractedTime(from: precomputed, snapshots: snapshots, categories: []), 0)
    XCTAssertEqual(DaySummaryStats.computeTotalCapturedTime(from: precomputed, categories: []), 300)
    let durations = DaySummaryStats.computeCategoryDurations(from: precomputed, categories: [])
    XCTAssertEqual(durations.count, 1)
    XCTAssertEqual(durations.first?.name, String(localized: "Other"))
    XCTAssertEqual(durations.first?.duration, 300)
    XCTAssertTrue(export.contains(String(localized: "Other")))
  }


  func testAtomicReplacementRollsBackSecondFailureAndPreservesGap() throws {
    XCTAssertTrue(AppStoragePaths.isIsolated)
    let storage = StorageManager.shared
    let base = 1_950_000_000
    let batch: Int64 = try storage.db.write { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base, base + 300])
      return db.lastInsertedRowID
    }
    defer { try? storage.db.write { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [batch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [batch])
    } }
    let newerBatch: Int64 = try storage.db.write { db in
      try db.execute(sql: "INSERT INTO analysis_batches(batch_start_ts,batch_end_ts) VALUES (?,?)", arguments: [base + 90, base + 180])
      return db.lastInsertedRowID
    }
    defer { try? storage.db.write { db in
      try db.execute(sql: "DELETE FROM timeline_cards WHERE batch_id = ?", arguments: [newerBatch])
      try db.execute(sql: "DELETE FROM analysis_batches WHERE id = ?", arguments: [newerBatch])
    } }
    let newerID: Int64 = try storage.db.write { db in
      try db.execute(sql: """
        INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
        VALUES (?, '1:02 PM', '1:03 PM', ?, ?, '2031-10-17', 'newer', 'A', '', '')
        """, arguments: [newerBatch, base + 120, base + 180])
      return db.lastInsertedRowID
    }
    let initial: [Int64] = try storage.db.write { db in
      var ids: [Int64] = []
      for (start, end, title) in [(base, base + 60, "old"), (base + 60, base + 120, "gap")] {
        try db.execute(sql: """
          INSERT INTO timeline_cards(batch_id,start,end,start_ts,end_ts,day,title,category,summary,detailed_summary)
          VALUES (?, '1:00 PM', '1:01 PM', ?, ?, '2031-10-17', ?, 'A', '', '')
          """, arguments: [batch, start, end, title])
        ids.append(db.lastInsertedRowID)
      }
      return ids
    }
    let format = TimelineOutputPolicy()
    func shell(_ start: Int, _ end: Int, invalid: Bool = false) -> TimelineCardShell {
      TimelineCardShell(startTimestamp: invalid ? "not a time" : format.formatTimestampForPrompt(start),
        endTimestamp: format.formatTimestampForPrompt(end), category: "A", subcategory: "",
        title: "replacement", summary: "", detailedSummary: "", distractions: nil, appSites: nil)
    }
    func group(_ start: Int, _ end: Int, invalid: Bool = false) -> TimelineCardReplacementGroup {
      TimelineCardReplacementGroup(from: Date(timeIntervalSince1970: Double(start)),
        to: Date(timeIntervalSince1970: Double(end)), cards: [shell(start, end, invalid: invalid)])
    }
    XCTAssertThrowsError(try storage.replaceTimelineCardGroups(
      [group(base, base + 60), group(base + 120, base + 180, invalid: true)], batchId: batch,
      keepingNewerBatchesCardsStartingAfter: nil))
    XCTAssertNotNil(storage.fetchTimelineCard(byId: initial[0]))
    XCTAssertNotNil(storage.fetchTimelineCard(byId: initial[1]))
    let count: Int = try storage.db.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM timeline_cards WHERE batch_id = ?", arguments: [batch]) ?? 0
    }
    XCTAssertEqual(count, 2)
    let result = try storage.replaceTimelineCardGroups(
      [group(base, base + 60), group(base + 120, base + 180)], batchId: batch,
      keepingNewerBatchesCardsStartingAfter: Date(timeIntervalSince1970: Double(base)))
    XCTAssertEqual(result.insertedIds.count, 2)
    XCTAssertNil(storage.fetchTimelineCard(byId: initial[0]))
    XCTAssertNotNil(storage.fetchTimelineCard(byId: initial[1]))
    XCTAssertNotNil(storage.fetchTimelineCard(byId: newerID))
  }

}
