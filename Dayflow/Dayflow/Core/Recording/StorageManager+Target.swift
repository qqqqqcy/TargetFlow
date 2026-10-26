import Foundation
import GRDB

protocol TargetStorage {
  func fetchTargetAssessments() throws -> [TargetAssessment]
  func saveTargetAssessment(_ assessment: TargetAssessment, card: TimelineCardWithTimestamps) throws
    -> Bool
  func targetCandidateCardIDs(since date: Date) throws -> [Int64]
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps?
  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation]
}

extension StorageManager: TargetStorage {
  func fetchTargetAssessments() throws -> [TargetAssessment] {
    try timedRead("fetchTargetAssessments") { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT a.assessment_json FROM target_assessments a
          JOIN timeline_cards c ON c.id = a.card_id
          WHERE c.is_deleted = 0
          ORDER BY c.end_ts DESC LIMIT 1000
          """)
      return rows.compactMap { row in
        let json: String = row["assessment_json"]
        return try? JSONDecoder().decode(TargetAssessment.self, from: Data(json.utf8))
      }
    }
  }

  @discardableResult
  func saveTargetAssessment(_ assessment: TargetAssessment, card: TimelineCardWithTimestamps) throws
    -> Bool
  {
    let json = String(decoding: try JSONEncoder().encode(assessment), as: UTF8.self)
    return try timedWrite("saveTargetAssessment") { db in
      // Cards may be removed or extended while the AI request is running.
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO target_assessments (card_id, assessment_json)
          SELECT id, ? FROM timeline_cards
          WHERE id = ? AND is_deleted = 0 AND start_ts = ? AND end_ts = ?
            AND title = ? AND COALESCE(summary, '') = ? AND COALESCE(detailed_summary, '') = ?
          """,
        arguments: [
          json, card.id, card.startTs, card.endTs, card.title, card.summary, card.detailedSummary,
        ])
      return db.changesCount > 0
    }
  }

  func targetCandidateCardIDs(since date: Date) throws -> [Int64] {
    try timedRead("targetCandidateCardIDs") { db in
      try Int64.fetchAll(
        db,
        sql: """
          SELECT id FROM timeline_cards
          WHERE is_deleted = 0 AND end_ts > ? AND category != 'System'
          ORDER BY end_ts DESC LIMIT 100
          """, arguments: [date.timeIntervalSince1970])
    }
  }
}
