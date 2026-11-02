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
      // The assessment depends on both content and structured evidence. Compare inside
      // the same write transaction so an old model response cannot overwrite newer data.
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT metadata FROM timeline_cards
          WHERE id = ? AND is_deleted = 0 AND start_ts = ? AND end_ts = ? AND category = ?
            AND title = ? AND COALESCE(summary, '') = ? AND COALESCE(detailed_summary, '') = ?
          """,
        arguments: [card.id, card.startTs, card.endTs, card.category, card.title,
                    card.summary, card.detailedSummary]
      ) else { return false }
      var evidence: ActivityEvidenceKind?
      var distractions: [Distraction]?
      if let raw: String = row["metadata"] {
        let data = Data(raw.utf8)
        let decoder = JSONDecoder()
        if let metadata = try? decoder.decode(TimelineMetadata.self, from: data) {
          evidence = metadata.evidenceKind
          distractions = metadata.distractions
        } else if let legacy = try? decoder.decode([Distraction].self, from: data) {
          distractions = legacy
        } else {
          // Malformed or unknown metadata cannot safely be matched to an old response.
          return false
        }
      }
      func semanticDistractions(_ values: [Distraction]?) -> [[String?]]? {
        values?.map { [$0.startTime, $0.endTime, $0.title, $0.summary] }
      }
      // Legacy JSON may omit distraction IDs, which are regenerated on every decode.
      guard evidence == card.evidenceKind,
        semanticDistractions(distractions) == semanticDistractions(card.distractions)
      else { return false }
      try db.execute(
        sql: "INSERT OR REPLACE INTO target_assessments (card_id, assessment_json) VALUES (?, ?)",
        arguments: [card.id, json])
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
