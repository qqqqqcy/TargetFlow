import Foundation
import GRDB

extension StorageManager {
  func deleteObservations(forBatchIds batchIds: [Int64]) {
    guard !batchIds.isEmpty else { return }

    try? db.write { db in
      let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")
      try db.execute(
        sql: """
              DELETE FROM observations WHERE batch_id IN (\(placeholders))
          """, arguments: StatementArguments(batchIds))
    }
  }

  func resetBatchStatuses(forBatchIds batchIds: [Int64]) -> [Int64] {
    guard !batchIds.isEmpty else { return [] }
    var affectedBatchIds: [Int64] = []
    let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")

    do {
      try timedWrite("resetBatchStatuses(forBatchIds:\(batchIds.count))") { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
                SELECT id FROM analysis_batches
                WHERE id IN (\(placeholders))
            """,
          arguments: StatementArguments(batchIds)
        )

        affectedBatchIds = rows.compactMap { $0["id"] as? Int64 }
        guard !affectedBatchIds.isEmpty else { return }

        let affectedPlaceholders = Array(repeating: "?", count: affectedBatchIds.count).joined(
          separator: ",")
        try db.execute(
          sql: """
                UPDATE analysis_batches
                SET status = 'pending', reason = NULL, llm_metadata = NULL
                WHERE id IN (\(affectedPlaceholders))
            """,
          arguments: StatementArguments(affectedBatchIds)
        )
      }
    } catch {
      print("resetBatchStatuses(forBatchIds:) failed: \(error)")
    }

    return affectedBatchIds
  }

}
