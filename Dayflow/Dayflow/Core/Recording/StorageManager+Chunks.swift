import Foundation
import GRDB

extension StorageManager {
  // Keep status ordering aligned with the atomic timeline transaction. A delayed
  // asynchronous failure write could otherwise overwrite a successful retry.
  func updateBatchStatus(batchId: Int64, status: String) {
    try? timedWrite("updateBatchStatus") { db in
      try db.execute(sql: "UPDATE analysis_batches SET status = ? WHERE id = ?", arguments: [status, batchId])
    }
  }

  func markBatchFailed(batchId: Int64, reason: String) {
    try? timedWrite("markBatchFailed") { db in
      try db.execute(sql: "UPDATE analysis_batches SET status = 'failed', reason = ? WHERE id = ?", arguments: [reason, batchId])
    }
  }


}
