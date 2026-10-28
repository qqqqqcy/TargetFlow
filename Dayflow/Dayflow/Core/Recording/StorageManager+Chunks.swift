import Foundation
import GRDB

extension StorageManager {
  func updateBatchStatus(batchId: Int64, status: String) {
    // Perform database write asynchronously to avoid blocking caller thread
    dbWriteQueue.async { [weak self] in
      try? self?.timedWrite("updateBatchStatus") { db in
        try db.execute(
          sql: "UPDATE analysis_batches SET status = ? WHERE id = ?", arguments: [status, batchId])
      }
    }
  }

  func markBatchFailed(batchId: Int64, reason: String) {
    // Perform database write asynchronously to avoid blocking caller thread
    dbWriteQueue.async { [weak self] in
      try? self?.timedWrite("markBatchFailed") { db in
        try db.execute(
          sql: "UPDATE analysis_batches SET status = 'failed', reason = ? WHERE id = ?",
          arguments: [reason, batchId])
      }
    }
  }


}
