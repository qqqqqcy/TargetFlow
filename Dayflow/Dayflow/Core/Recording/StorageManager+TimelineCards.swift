import Foundation
import GRDB

extension Notification.Name {
  static let timelineCardsDidCommit = Notification.Name("timelineCardsDidCommit")
}

struct TimelineCardReplacementGroup {
  let from: Date
  let to: Date
  let cards: [TimelineCardShell]
  let preservingStartOfCardId: Int64?
  /// Mature continuous evidence can contain several stable labels. The interval
  /// is a stabilization window, not a minimum duration for each displayed card.
  let stabilityWindow: Range<Int>?

  init(from: Date, to: Date, cards: [TimelineCardShell], preservingStartOfCardId: Int64? = nil,
    stabilityWindow: Range<Int>? = nil) {
    self.from = from
    self.to = to
    self.cards = cards
    self.preservingStartOfCardId = preservingStartOfCardId
    self.stabilityWindow = stabilityWindow
  }
}

struct PendingTimelineEvidence {
  let id: Int64?
  let batchId: Int64
  let startTs: Int
  let endTs: Int
  let card: ActivityCardData
  let firstScreenshotId: Int64
  let lastScreenshotId: Int64
  var sourceScreenshotIds: [Int64] = []
}

enum TimelineCardReplacementError: Error, Equatable, LocalizedError {
  case invalidGroup
  case invalidCardTime
  case minimumDurationChanged
  case pendingChanged
  case sourceEvidenceChanged
  case timelineChanged

  var errorDescription: String? {
    if self == .timelineChanged {
      return String(localized: "The timeline changed while this recording was being analyzed. Retry with the latest events.")
    }
    return nil
  }
}

extension StorageManager {
  private func requireTimelineSources(in db: Database, screenshotIds: [Int64], pendingIds: [Int64], cardIds: [Int64]) throws {
    let ids = Array(Set(screenshotIds))
    for start in stride(from: 0, to: ids.count, by: 400) {
      let chunk = Array(ids[start..<min(start + 400, ids.count)])
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots WHERE COALESCE(is_deleted, 0) = 0 AND id IN (\(placeholders))",
        arguments: StatementArguments(chunk)) ?? 0
      guard active == chunk.count else { throw TimelineCardReplacementError.sourceEvidenceChanged }
    }
    for id in Set(pendingIds) {
      let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pending_timeline_evidence WHERE id = ?)", arguments: [id]) ?? false
      guard exists else { throw TimelineCardReplacementError.sourceEvidenceChanged }
    }
    for id in Set(cardIds) {
      let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM timeline_cards WHERE id = ? AND is_deleted = 0)", arguments: [id]) ?? false
      guard exists else { throw TimelineCardReplacementError.sourceEvidenceChanged }
    }
  }

  func timelineSourcesAreActive(screenshotIds: [Int64], pendingIds: [Int64], cardIds: [Int64] = []) -> Bool {
    (try? timedRead("timelineSourcesAreActive") { db in
      try requireTimelineSources(in: db, screenshotIds: screenshotIds, pendingIds: pendingIds, cardIds: cardIds)
      return true
    }) ?? false
  }

  func pendingTimelineEvidence() -> [PendingTimelineEvidence] {
    (try? timedRead("pendingTimelineEvidence") { db in
      try Row.fetchAll(db, sql: """
        SELECT p.* FROM pending_timeline_evidence p
        JOIN screenshots a ON a.id = p.first_screenshot_id AND a.is_deleted = 0
        JOIN screenshots b ON b.id = p.last_screenshot_id AND b.is_deleted = 0
        WHERE NOT EXISTS (SELECT 1 FROM pending_timeline_sources ps
          LEFT JOIN screenshots s ON s.id = ps.screenshot_id
          WHERE ps.pending_id = p.id AND (s.id IS NULL OR COALESCE(s.is_deleted, 0) != 0))
        ORDER BY p.start_ts
        """).compactMap { row in
          guard let json: String = row["card_json"],
            let card = try? JSONDecoder().decode(ActivityCardData.self, from: Data(json.utf8))
          else { return nil }
          let id: Int64 = row["id"]
          let sourceIds = (try? Int64.fetchAll(db, sql: "SELECT screenshot_id FROM pending_timeline_sources WHERE pending_id = ?", arguments: [id])) ?? []
          return PendingTimelineEvidence(id: id, batchId: row["batch_id"],
            startTs: row["start_ts"], endTs: row["end_ts"], card: card,
            firstScreenshotId: row["first_screenshot_id"], lastScreenshotId: row["last_screenshot_id"],
            sourceScreenshotIds: sourceIds)
        }
    }) ?? []
  }

  func deleteTimelineCard(recordId: Int64) -> String? {
    var videoPath: String? = nil

    try? timedWrite("deleteTimelineCard(recordId:\(recordId))") { db in
      guard
        let cardRow = try Row.fetchOne(
          db,
          sql: """
                SELECT video_summary_url, start_ts, end_ts, batch_id
                FROM timeline_cards
                WHERE id = ?
                  AND is_deleted = 0
            """,
          arguments: [recordId]
        )
      else {
        return
      }

      videoPath = cardRow["video_summary_url"]

      let startTs: Int = cardRow["start_ts"] ?? 0
      let endTs: Int = cardRow["end_ts"] ?? 0
      let batchId: Int64? = cardRow["batch_id"]

      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET is_deleted = 1
              WHERE id = ?
                AND is_deleted = 0
          """,
        arguments: [recordId]
      )

      guard endTs > startTs else { return }
      // Pending rewrites may include this card's facts; deleting the card must
      // not allow a later settings change to recreate it.
      try db.execute(sql: "DELETE FROM pending_timeline_evidence WHERE start_ts < ? AND end_ts > ?",
        arguments: [endTs, startTs])

      if let batchId {
        try db.execute(
          sql: """
                DELETE FROM observations
                WHERE batch_id = ?
                  AND ((start_ts < ? AND end_ts > ?)
                    OR (start_ts >= ? AND start_ts < ?))
            """,
          arguments: [batchId, endTs, startTs, startTs, endTs]
        )
      } else {
        try db.execute(
          sql: """
                DELETE FROM observations
                WHERE (start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?)
            """,
          arguments: [endTs, startTs, startTs, endTs]
        )
      }
    }

    return videoPath
  }

  func updateTimelineCardCategory(cardId: Int64, category: String) {
    let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return }

    try? updateTimelineCard(cardId: cardId, title: nil, category: trimmed)
  }

  func updateTimelineCardTitle(cardId: Int64, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return }

    try? updateTimelineCard(cardId: cardId, title: trimmed, category: nil)
  }

  /// Applies every requested activity field in one transaction. Agent writes use the
  /// throwing form so a database failure is returned instead of reported as success.
  func updateTimelineCard(cardId: Int64, title: String?, category: String?) throws {
    guard title != nil || category != nil else { return }

    try timedWrite("updateTimelineCard") { db in
      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET title = COALESCE(?, title),
                  category = COALESCE(?, category)
              WHERE id = ?
          """, arguments: [title, category, cardId])
    }
    NotificationCenter.default.post(name: .timelineCardsDidCommit, object: nil)
  }

  // All batches, newest first
  func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)] {
    (try? db.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT id, batch_start_ts, batch_end_ts, status FROM analysis_batches ORDER BY id DESC"
      ).map { row in
        (row["id"], row["batch_start_ts"], row["batch_end_ts"], row["status"])
      }
    }) ?? []
  }

  func fetchTimelineCards(forDay day: String) -> [TimelineCard] {
    let decoder = JSONDecoder()

    guard let dayDate = dateFormatter.date(from: day) else {
      return []
    }

    let calendar = Calendar.current

    // Get 4 AM of the given day as the start
    var startComponents = calendar.dateComponents([.year, .month, .day], from: dayDate)
    startComponents.hour = 4
    startComponents.minute = 0
    startComponents.second = 0
    guard let dayStart = calendar.date(from: startComponents) else { return [] }

    // Get 4 AM of the next day as the end
    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayDate) else { return [] }
    var endComponents = calendar.dateComponents([.year, .month, .day], from: nextDay)
    endComponents.hour = 4
    endComponents.minute = 0
    endComponents.second = 0
    guard let dayEnd = calendar.date(from: endComponents) else { return [] }

    let startTs = Int(dayStart.timeIntervalSince1970)
    let endTs = Int(dayEnd.timeIntervalSince1970)

    let cards: [TimelineCard]? = try? timedRead("fetchTimelineCards(forDay:\(day))") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM timeline_cards
              WHERE start_ts >= ? AND start_ts < ?
                AND is_deleted = 0
              ORDER BY start_ts ASC, start ASC
          """, arguments: [startTs, endTs]
      )
      .map { row in
        // Decode metadata JSON (supports object or legacy array)
        var distractions: [Distraction]? = nil
        var appSites: AppSites? = nil
        var isBackupGenerated: Bool? = nil
        var evidenceKind: ActivityEvidenceKind? = nil
        if let metadataString: String = row["metadata"],
          let jsonData = metadataString.data(using: .utf8)
        {
          if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
            distractions = meta.distractions
            appSites = meta.appSites
            isBackupGenerated = meta.isBackupGenerated
            evidenceKind = meta.evidenceKind
          } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
            distractions = legacy
          }
        }

        // Create TimelineCard instance using renamed columns.
        // subcategory/summary/detailed_summary are nullable in the schema —
        // decode NULL as "" because the model fields are non-optional and would trap.
        return TimelineCard(
          recordId: row["id"],
          batchId: row["batch_id"],
          startTimestamp: row["start"] ?? "",  // Use row["start"]
          endTimestamp: row["end"] ?? "",  // Use row["end"]
          category: row["category"],
          subcategory: row["subcategory"] ?? "",
          title: row["title"],
          summary: row["summary"] ?? "",
          detailedSummary: row["detailed_summary"] ?? "",
          day: row["day"],
          distractions: distractions,
          videoSummaryURL: row["video_summary_url"],
          otherVideoSummaryURLs: nil,
          appSites: appSites,
          isBackupGenerated: isBackupGenerated,
          evidenceKind: evidenceKind,
          startTs: row["start_ts"],
          endTs: row["end_ts"]
        )
      }
    }
    return cards ?? []
  }

  func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard] {
    let decoder = JSONDecoder()
    let fromTs = Int(from.timeIntervalSince1970)
    let toTs = Int(to.timeIntervalSince1970)

    let cards: [TimelineCard]? = try? timedRead("fetchTimelineCardsByTimeRange") { db in
      // Intentionally NO `category != 'System'` filter — System/"Processing
      // failed" cards surface in Day view via `fetchTimelineCards(forDay:)`
      // and should be visible in Week view too for parity. Rendering in
      // Week's card layer handles System cards via the generic category
      // palette (falls back to a neutral accent).
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM timeline_cards
              WHERE ((start_ts < ? AND end_ts > ?)
                 OR (start_ts >= ? AND start_ts < ?))
                AND is_deleted = 0
              ORDER BY start_ts ASC
          """, arguments: [toTs, fromTs, fromTs, toTs]
      )
      .map { row in
        // Decode metadata JSON (supports object or legacy array)
        var distractions: [Distraction]? = nil
        var appSites: AppSites? = nil
        var isBackupGenerated: Bool? = nil
        var evidenceKind: ActivityEvidenceKind? = nil
        if let metadataString: String = row["metadata"],
          let jsonData = metadataString.data(using: .utf8)
        {
          if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
            distractions = meta.distractions
            appSites = meta.appSites
            isBackupGenerated = meta.isBackupGenerated
            evidenceKind = meta.evidenceKind
          } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
            distractions = legacy
          }
        }

        // Create TimelineCard instance using renamed columns.
        // subcategory/summary/detailed_summary are nullable in the schema —
        // decode NULL as "" because the model fields are non-optional and would trap.
        return TimelineCard(
          recordId: row["id"],
          batchId: row["batch_id"],
          startTimestamp: row["start"] ?? "",
          endTimestamp: row["end"] ?? "",
          category: row["category"],
          subcategory: row["subcategory"] ?? "",
          title: row["title"],
          summary: row["summary"] ?? "",
          detailedSummary: row["detailed_summary"] ?? "",
          day: row["day"],
          distractions: distractions,
          videoSummaryURL: row["video_summary_url"],
          otherVideoSummaryURLs: nil,
          appSites: appSites,
          isBackupGenerated: isBackupGenerated,
          evidenceKind: evidenceKind,
          startTs: row["start_ts"],
          endTs: row["end_ts"]
        )
      }
    }
    let result = cards ?? []
    return result
  }

  func hasTimelineCardConnected(
    toBatchStartingAt batchStart: Date,
    maxGap: TimeInterval
  ) -> Bool {
    let batchStartTs = Int(batchStart.timeIntervalSince1970)
    let earliestEndTs = batchStartTs - Int(maxGap)

    return
      (try? timedRead("hasTimelineCardConnected") { db in
        try Bool.fetchOne(
          db,
          sql: """
                SELECT EXISTS(
                  SELECT 1
                  FROM timeline_cards
                  WHERE start_ts <= ?
                    AND end_ts >= ?
                    AND is_deleted = 0
                    AND category != 'System'
                )
            """,
          arguments: [batchStartTs, earliestEndTs]
        ) ?? false
      }) ?? false
  }

  func fetchTotalMinutesTracked(from: Date, to: Date) -> Double {
    let startTs = Int(from.timeIntervalSince1970)
    let endTs = Int(to.timeIntervalSince1970)

    let totalSeconds: Double? = try? timedRead("fetchTotalMinutesTracked") { db in
      try Double.fetchOne(
        db,
        sql: """
              SELECT COALESCE(SUM(end_ts - start_ts), 0)
              FROM timeline_cards
              WHERE start_ts >= ? AND start_ts < ?
              AND is_deleted = 0
              AND category != 'System'
          """,
        arguments: [startTs, endTs]
      )
    }

    return (totalSeconds ?? 0) / 60.0
  }

  func updateStorageLimit(bytes: Int64) {
    let previous = StoragePreferences.recordingsLimitBytes
    StoragePreferences.recordingsLimitBytes = bytes

    if bytes < previous {
      purgeIfNeeded()
    }
  }

  /// Fetch a specific timeline card by ID including timestamp fields
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? {
    let decoder = JSONDecoder()

    return try? timedRead("fetchTimelineCard(byId)") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT * FROM timeline_cards
                WHERE id = ?
                  AND is_deleted = 0
            """, arguments: [id])
      else { return nil }

      // Decode distractions from metadata JSON
      var distractions: [Distraction]? = nil
      var evidenceKind: ActivityEvidenceKind? = nil
      if let metadataString: String = row["metadata"],
        let jsonData = metadataString.data(using: .utf8)
      {
        if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
          distractions = meta.distractions
          evidenceKind = meta.evidenceKind
        } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
          distractions = legacy
        }
      }

      // subcategory/summary/detailed_summary are nullable in the schema —
      // decode NULL as "" because the model fields are non-optional and would trap.
      return TimelineCardWithTimestamps(
        id: id,
        startTimestamp: row["start"] ?? "",
        endTimestamp: row["end"] ?? "",
        startTs: row["start_ts"] ?? 0,
        endTs: row["end_ts"] ?? 0,
        category: row["category"],
        subcategory: row["subcategory"] ?? "",
        title: row["title"],
        summary: row["summary"] ?? "",
        detailedSummary: row["detailed_summary"] ?? "",
        day: row["day"],
        distractions: distractions,
        videoSummaryURL: row["video_summary_url"],
        evidenceKind: evidenceKind
      )
    }
  }

  /// The card right before a batch: of the cards that start before it, the one ending last.
  /// Its end can fall after the batch's start, because card times are rounded to the minute.
  func fetchTimelineCardEndingLast(startingBefore: Date, excludingBatchId: Int64)
    -> TimelineCardWithTimestamps?
  {
    let decoder = JSONDecoder()
    let beforeTs = Int(startingBefore.timeIntervalSince1970)

    return try? timedRead("fetchTimelineCardEndingLast(startingBefore:)") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT *
                FROM timeline_cards
                WHERE start_ts < ?
                  AND batch_id IS NOT ?
                  AND is_deleted = 0
                ORDER BY end_ts DESC, id DESC
                LIMIT 1
            """,
          arguments: [beforeTs, excludingBatchId]
        )
      else {
        return nil
      }

      var distractions: [Distraction]? = nil
      var evidenceKind: ActivityEvidenceKind? = nil
      if let metadataString: String = row["metadata"],
        let jsonData = metadataString.data(using: .utf8)
      {
        if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
          distractions = meta.distractions
          evidenceKind = meta.evidenceKind
        } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
          distractions = legacy
        }
      }

      // subcategory/summary/detailed_summary are nullable in the schema —
      // decode NULL as "" because the model fields are non-optional and would trap.
      return TimelineCardWithTimestamps(
        id: row["id"],
        startTimestamp: row["start"] ?? "",
        endTimestamp: row["end"] ?? "",
        startTs: row["start_ts"] ?? 0,
        endTs: row["end_ts"] ?? 0,
        category: row["category"],
        subcategory: row["subcategory"] ?? "",
        title: row["title"],
        summary: row["summary"] ?? "",
        detailedSummary: row["detailed_summary"] ?? "",
        day: row["day"],
        distractions: distractions,
        videoSummaryURL: row["video_summary_url"],
        evidenceKind: evidenceKind
      )
    }
  }

  /// Writes an idle batch's card without touching other batches' cards. The only cards removed
  /// are this batch's own earlier ones: an error card from a failed attempt, or output from an
  /// earlier run. With `extendingCardId`, that previous idle card is stretched to `endTs`
  /// instead of adding a new card.
  func saveIdleBatchCard(
    _ card: TimelineCardShell, startTs: Int, endTs: Int, batchId: Int64, extendingCardId: Int64?
  ) -> (cardId: Int64?, deletedVideoPaths: [String]) {
    let metadata = TimelineMetadata(
      distractions: nil, appSites: nil, isBackupGenerated: nil, idle: card.idleMetadata,
      evidenceKind: card.evidenceKind)
    let metadataString = (try? JSONEncoder().encode(metadata)).flatMap {
      String(data: $0, encoding: .utf8)
    }
    let startDate = Date(timeIntervalSince1970: TimeInterval(startTs))
    let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary()

    var cardId: Int64?
    var videoPaths: [String] = []
    let committed: Bool = (try? timedWrite("saveIdleBatchCard") { db in
      videoPaths = try String.fetchAll(
        db,
        sql: """
              SELECT video_summary_url FROM timeline_cards
              WHERE batch_id = ? AND is_deleted = 0 AND video_summary_url IS NOT NULL
          """, arguments: [batchId])
      try db.execute(
        sql: "UPDATE timeline_cards SET is_deleted = 1 WHERE batch_id = ? AND is_deleted = 0",
        arguments: [batchId])

      if let extendingCardId {
        try db.execute(
          sql: """
                UPDATE timeline_cards
                SET end = ?, end_ts = ?, metadata = ?
                WHERE id = ? AND is_deleted = 0
            """,
          arguments: [card.endTimestamp, endTs, metadataString, extendingCardId])
        cardId = db.changesCount > 0 ? extendingCardId : nil
      } else {
        try db.execute(
          sql: """
                INSERT INTO timeline_cards(
                    batch_id, start, end, start_ts, end_ts, day, title,
                    summary, category, subcategory, detailed_summary, metadata
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            batchId, card.startTimestamp, card.endTimestamp, startTs, endTs, dayString, card.title,
            card.summary, card.category, card.subcategory, card.detailedSummary, metadataString,
          ])
        cardId = db.lastInsertedRowID
      }
      return true
    }) ?? false
    if committed { NotificationCenter.default.post(name: .timelineCardsDidCommit, object: nil) }
    return (cardId, videoPaths)
  }

  /// Soft-deletes the cards in the range and inserts the new ones.
  ///
  /// Pass `keepingNewerBatchesCardsStartingAfter` (this batch's start) when the caller never
  /// showed its model the cards of newer batches, which happens when this batch finishes after a
  /// newer one, such as a retry. Cards from batches that started later and that begin after that
  /// moment then stay, even where clock times rounded to the minute make them overlap the range.
  func replaceTimelineCardsInRange(
    from: Date, to: Date, with newCards: [TimelineCardShell], batchId: Int64,
    keepingNewerBatchesCardsStartingAfter keepAfter: Date?
  ) -> (insertedIds: [Int64], deletedVideoPaths: [String]) {
    (try? replaceTimelineCardGroups(
      [TimelineCardReplacementGroup(from: from, to: to, cards: newCards)], batchId: batchId,
      keepingNewerBatchesCardsStartingAfter: keepAfter)) ?? ([], [])
  }

  /// Replaces all disconnected spans atomically; a failure rolls back every span.
  func replaceTimelineCardGroups(
    _ groups: [TimelineCardReplacementGroup], batchId: Int64,
    keepingNewerBatchesCardsStartingAfter keepAfter: Date?,
    pendingToSave: [PendingTimelineEvidence] = [], pendingToDelete: [Int64] = [],
    enforceMinimum: Bool = false, markBatchAnalyzed: Bool = false,
    replacementObservations: [Observation]? = nil,
    requiredScreenshotIds: [Int64] = [], requiredPendingIds: [Int64] = [],
    requiredCardIds: [Int64] = [], expectedTimeline: TimelineRewriteSnapshot? = nil
  ) throws -> (insertedIds: [Int64], deletedVideoPaths: [String]) {
    var clearedFailurePlaceholder = false
    let result = try timedWrite("replaceTimelineCardGroups") { db in
      // The model and classifier run outside this transaction. Every frame they
      // used must still be present and active when their result is committed.
      try requireTimelineSources(in: db, screenshotIds: requiredScreenshotIds, pendingIds: requiredPendingIds, cardIds: requiredCardIds)
      if let expectedTimeline {
        guard try timelineRewriteMatches(in: db, snapshot: expectedTimeline,
          groups: groups, pendingToSave: pendingToSave, pendingToDelete: pendingToDelete,
          markBatchAnalyzed: markBatchAnalyzed, batchId: batchId, requiredCardIds: requiredCardIds)
        else { throw TimelineCardReplacementError.timelineChanged }
      }
      if enforceMinimum {
        let minimum = Int(AnalysisPreferences.interval)
        for group in groups {
          if let keepAfter {
            let keepTs = Int(keepAfter.timeIntervalSince1970)
            let overlapsNewer = try Bool.fetchOne(db, sql: """
              SELECT EXISTS(SELECT 1 FROM timeline_cards
                WHERE is_deleted = 0 AND start_ts < ? AND end_ts > ? AND start_ts > ?
                  AND batch_id IN (SELECT id FROM analysis_batches WHERE batch_start_ts > ?))
              """, arguments: [Int(group.to.timeIntervalSince1970), Int(group.from.timeIntervalSince1970), keepTs, keepTs]) ?? false
            guard !overlapsNewer else { throw TimelineCardReplacementError.invalidGroup }
          }
          for card in group.cards where card.category != "System" {
            guard let start = card.exactStartTs, let end = card.exactEndTs, end > start else {
              throw TimelineCardReplacementError.minimumDurationChanged
            }
            if let window = group.stabilityWindow {
              guard window.upperBound - window.lowerBound >= minimum,
                window.lowerBound <= start, end <= window.upperBound else {
                throw TimelineCardReplacementError.minimumDurationChanged
              }
            } else if end - start < minimum {
              throw TimelineCardReplacementError.minimumDurationChanged
            }
          }
        }
      }
      for id in pendingToDelete {
        try db.execute(sql: "DELETE FROM pending_timeline_evidence WHERE id = ?", arguments: [id])
        guard db.changesCount == 1 else { throw TimelineCardReplacementError.pendingChanged }
      }
      for pending in pendingToSave {
        let json = String(decoding: try JSONEncoder().encode(pending.card), as: UTF8.self)
        try db.execute(sql: """
          INSERT INTO pending_timeline_evidence(batch_id,start_ts,end_ts,card_json,first_screenshot_id,last_screenshot_id)
          VALUES (?,?,?,?,?,?)
          """, arguments: [pending.batchId, pending.startTs, pending.endTs, json,
            pending.firstScreenshotId, pending.lastScreenshotId])
        let pendingId = db.lastInsertedRowID
        for screenshotId in Set(pending.sourceScreenshotIds + [pending.firstScreenshotId, pending.lastScreenshotId]) {
          try db.execute(sql: "INSERT INTO pending_timeline_sources(pending_id,screenshot_id) VALUES (?,?)",
            arguments: [pendingId, screenshotId])
        }
      }
      var ids: [Int64] = []
      var paths: [String] = []
      var previousEnd: Date?
      for group in groups {
        guard group.from < group.to, !group.cards.isEmpty,
          previousEnd.map({ $0 <= group.from }) ?? true
        else { throw TimelineCardReplacementError.invalidGroup }
        let result = try replaceTimelineCardsInRange(
          in: db, from: group.from, to: group.to, with: group.cards,
          batchId: batchId, keepingNewerBatchesCardsStartingAfter: keepAfter,
          preservingStartOfCardId: group.preservingStartOfCardId)
        ids += result.insertedIds
        paths += result.deletedVideoPaths
        previousEnd = group.to
      }
      if let replacementObservations {
        try db.execute(sql: "DELETE FROM observations WHERE batch_id = ?", arguments: [batchId])
        for observation in replacementObservations {
          try db.execute(sql: """
            INSERT INTO observations(batch_id, start_ts, end_ts, observation, metadata, llm_model)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [batchId, observation.startTs, observation.endTs,
              observation.observation, observation.metadata, observation.llmModel])
        }
      }
      if markBatchAnalyzed {
        // Success may produce only pending fragments, with no published ranges
        // to replace the old error card. Clear this batch's placeholders in the
        // SAME transaction, never neighboring failures or ordinary history.
        paths += try String.fetchAll(db, sql: """
          SELECT video_summary_url FROM timeline_cards
          WHERE batch_id = ? AND category = 'System' AND title = 'Processing failed'
            AND is_deleted = 0 AND video_summary_url IS NOT NULL
          """, arguments: [batchId])
        try db.execute(sql: """
          UPDATE timeline_cards SET is_deleted = 1
          WHERE batch_id = ? AND category = 'System' AND title = 'Processing failed' AND is_deleted = 0
          """, arguments: [batchId])
        clearedFailurePlaceholder = db.changesCount > 0
        try db.execute(sql: "UPDATE analysis_batches SET status = 'analyzed', reason = NULL WHERE id = ?", arguments: [batchId])
      }
      return (ids, paths)
    }
    if !groups.isEmpty || clearedFailurePlaceholder { NotificationCenter.default.post(name: .timelineCardsDidCommit, object: nil) }
    return result
  }

  private func replaceTimelineCardsInRange(
    in db: Database, from: Date, to: Date, with newCards: [TimelineCardShell], batchId: Int64,
    keepingNewerBatchesCardsStartingAfter keepAfter: Date?, preservingStartOfCardId: Int64?
  ) throws -> (insertedIds: [Int64], deletedVideoPaths: [String]) {
    let requestedFromTs = Int(from.timeIntervalSince1970)
    let toTs = Int(to.timeIntervalSince1970)
    // A previous exact-time record can end inside the model's rounded first
    // minute. Preserve it and start the new record at the actual first capture.
    // This does not widen or rewrite the previous evidence.
    let batchStartTs = try Int.fetchOne(db, sql: "SELECT batch_start_ts FROM analysis_batches WHERE id = ?", arguments: [batchId])
    let hasEarlierPartial = try Bool.fetchOne(db, sql: """
      SELECT EXISTS(SELECT 1 FROM timeline_cards
        WHERE is_deleted = 0 AND category != 'System' AND COALESCE(batch_id, -1) != ?
          AND start_ts < ? AND end_ts > ? AND end_ts <= ?)
      """, arguments: [batchId, requestedFromTs, requestedFromTs, batchStartTs ?? requestedFromTs]) ?? false
    let preservedStart: Int?
    if let preservingStartOfCardId, let batchStartTs {
      preservedStart = try Int.fetchOne(db, sql: """
        SELECT start_ts FROM timeline_cards WHERE id = ? AND is_deleted = 0
          AND start_ts >= ? AND start_ts < ? AND start_ts < ? AND end_ts <= ?
          AND category != 'System'
        """, arguments: [preservingStartOfCardId, requestedFromTs, requestedFromTs + 60, batchStartTs, toTs])
      guard preservedStart != nil else { throw TimelineCardReplacementError.invalidGroup }
    } else {
      preservedStart = nil
    }
    let fromTs = preservedStart ?? (hasEarlierPartial ? (batchStartTs ?? requestedFromTs) : requestedFromTs)
    guard fromTs < toTs else { throw TimelineCardReplacementError.invalidGroup }
    let keepAfterTs = keepAfter.map { Int($0.timeIntervalSince1970) } ?? Int.max
    let encoder = JSONEncoder()
    var insertedIds: [Int64] = []
    var videoPaths: [String] = []
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")

    // Clock-only generated intervals cannot safely replace just part of a record
    // from any batch. Refuse the entire transaction instead of dropping its
    // uncovered seconds or historical details.
    let partialHistory = try Int.fetchOne(db, sql: """
      SELECT COUNT(*) FROM timeline_cards
      WHERE is_deleted = 0 AND category != 'System'
        AND start_ts < ? AND end_ts > ? AND (start_ts < ? OR end_ts > ?)
        AND NOT (start_ts > ? AND COALESCE(batch_id, -1) IN (
          SELECT id FROM analysis_batches WHERE batch_start_ts > ?))
      """, arguments: [toTs, fromTs, fromTs, toTs, keepAfterTs, keepAfterTs]) ?? 0
    guard partialHistory == 0 else { throw TimelineCardReplacementError.invalidGroup }

    // First, fetch the video paths that will be soft-deleted
    // Note: We exclude error cards (category='System') from other batches to preserve them
    let videoRows = try Row.fetchAll(
      db,
      sql: """
            SELECT video_summary_url FROM timeline_cards
            WHERE ((start_ts < ? AND end_ts > ?)
               OR (start_ts >= ? AND start_ts < ?))
               AND video_summary_url IS NOT NULL
               AND is_deleted = 0
               AND (category != 'System' OR batch_id = ?)
               AND NOT (start_ts > ? AND COALESCE(batch_id, -1) IN (
                 SELECT id FROM analysis_batches WHERE batch_start_ts > ?))
        """, arguments: [toTs, fromTs, fromTs, toTs, batchId, keepAfterTs, keepAfterTs])

    videoPaths = videoRows.compactMap { $0["video_summary_url"] as? String }

    // Soft delete existing cards in the range using timestamp columns
    // Preserve error cards (category='System') from other batches so they remain visible
    try db.execute(
      sql: """
            UPDATE timeline_cards
            SET is_deleted = 1
            WHERE ((start_ts < ? AND end_ts > ?)
               OR (start_ts >= ? AND start_ts < ?))
               AND is_deleted = 0
               AND (category != 'System' OR batch_id = ?)
               AND NOT (start_ts > ? AND COALESCE(batch_id, -1) IN (
                 SELECT id FROM analysis_batches WHERE batch_start_ts > ?))
        """, arguments: [toTs, fromTs, fromTs, toTs, batchId, keepAfterTs, keepAfterTs])

    // Insert new cards
    for (index, card) in newCards.enumerated() {
      // Encode metadata object with distractions and appSites
      let meta = TimelineMetadata(
        distractions: card.distractions,
        appSites: card.appSites,
        isBackupGenerated: card.isBackupGenerated,
        idle: card.idleMetadata,
        evidenceKind: card.evidenceKind
      )
      let metadataString: String? = (try? encoder.encode(meta)).flatMap {
        String(data: $0, encoding: .utf8)
      }

      // Resolve clock-only timestamps by picking the nearest day to the window midpoint
      let calendar = Calendar.current
      let anchor = from.addingTimeInterval(to.timeIntervalSince(from) / 2.0)

      let resolveClock: (Int, Int) -> Date = { hour, minute in
        guard
          let sameDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: anchor)
        else {
          return anchor
        }
        let previousDay = calendar.date(byAdding: .day, value: -1, to: sameDay) ?? sameDay
        let nextDay = calendar.date(byAdding: .day, value: 1, to: sameDay) ?? sameDay

        let candidates = [previousDay, sameDay, nextDay]
        return candidates.min { lhs, rhs in
          abs(lhs.timeIntervalSince(anchor)) < abs(rhs.timeIntervalSince(anchor))
        } ?? sameDay
      }

      guard let startTime = timeFormatter.date(from: card.startTimestamp),
        let endTime = timeFormatter.date(from: card.endTimestamp)
      else {
        throw TimelineCardReplacementError.invalidCardTime
      }

      let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
      guard let startHour = startComponents.hour, let startMinute = startComponents.minute else {
        throw TimelineCardReplacementError.invalidCardTime
      }

      let startDate = resolveClock(startHour, startMinute)

      let roundedStartTs = Int(startDate.timeIntervalSince1970)
      let startTs = card.exactStartTs ?? (index == 0 && fromTs > requestedFromTs ? max(roundedStartTs, fromTs) : roundedStartTs)

      let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
      guard let endHour = endComponents.hour, let endMinute = endComponents.minute else {
        throw TimelineCardReplacementError.invalidCardTime
      }

      var endDate = resolveClock(endHour, endMinute)

      // Handle midnight crossing: if end time is before start time, it must be the next day
      if endDate < startDate {
        endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
      }

      let endTs = card.exactEndTs ?? Int(endDate.timeIntervalSince1970)
      guard endTs > startTs else { throw TimelineCardReplacementError.invalidCardTime }
      if card.exactStartTs != nil || card.exactEndTs != nil {
        guard startTs >= fromTs, endTs <= toTs else { throw TimelineCardReplacementError.invalidGroup }
      }

      // Calculate the day string using 4 AM boundary rules
      let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary()

      try db.execute(
        sql: """
              INSERT INTO timeline_cards(
                  batch_id, start, end, start_ts, end_ts, day, title,
                  summary, category, subcategory, detailed_summary, metadata
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          batchId, card.startTimestamp, card.endTimestamp, startTs, endTs, dayString, card.title,
          card.summary, card.category, card.subcategory, card.detailedSummary, metadataString,
        ])

      // Capture the ID of the inserted card
      let insertedId = db.lastInsertedRowID
      insertedIds.append(insertedId)
    }
    return (insertedIds, videoPaths)
  }

  // Note: Transcript storage methods removed in favor of Observations table

}
