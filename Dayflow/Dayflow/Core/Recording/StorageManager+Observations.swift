import Foundation
import GRDB

extension StorageManager {
  func saveObservations(batchId: Int64, observations: [Observation]) {
    guard !observations.isEmpty else { return }
    try? timedWrite("saveObservations(\(observations.count)_items)") { db in
      for obs in observations {
        try db.execute(
          sql: """
                INSERT INTO observations(
                    batch_id, start_ts, end_ts, observation, metadata, llm_model
                )
                VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            batchId, obs.startTs, obs.endTs, obs.observation,
            obs.metadata, obs.llmModel,
          ])
      }
    }
  }

  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] {
    let fromTs = Int(from.timeIntervalSince1970)
    let toTs = Int(to.timeIntervalSince1970)

    return
      (try? db.read { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT * FROM observations
                WHERE (start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?)
                ORDER BY start_ts ASC
            """, arguments: [toTs, fromTs, fromTs, toTs]
        ).map { row in
          Observation(
            id: row["id"],
            batchId: row["batch_id"],
            startTs: row["start_ts"],
            endTs: row["end_ts"],
            observation: row["observation"],
            metadata: row["metadata"],
            llmModel: row["llm_model"],
            createdAt: row["created_at"]
          )
        }
      }) ?? []
  }

  func updateBatch(_ batchId: Int64, status: String, reason: String? = nil) {
    try? db.write { db in
      let sql = """
            UPDATE analysis_batches
            SET status = ?, reason = ?
            WHERE id = ?
        """
      try db.execute(sql: sql, arguments: [status, reason, batchId])
    }
  }

  var dateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  func insertLLMCall(_ rec: LLMCallDBRecord) {
    try? db.write { db in
      try db.execute(
        sql: """
              INSERT INTO llm_calls (
                  batch_id, call_group_id, attempt, provider, model, operation,
                  status, latency_ms, http_status, request_method, request_url,
                  request_headers, request_body, response_headers, response_body,
                  error_domain, error_code, error_message, usage_receipt
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          rec.batchId,
          rec.callGroupId,
          rec.attempt,
          rec.provider,
          rec.model,
          rec.operation,
          rec.status,
          rec.latencyMs,
          rec.httpStatus,
          rec.requestMethod,
          rec.requestURL,
          rec.requestHeadersJSON,
          rec.requestBody,
          rec.responseHeadersJSON,
          rec.responseBody,
          rec.errorDomain,
          rec.errorCode,
          rec.errorMessage,
          String(decoding: try JSONEncoder().encode(rec.usageReceipt), as: UTF8.self),
        ])
    }
    NotificationCenter.default.post(name: .llmUsageUpdated, object: nil)
  }

  func fetchLLMUsageSummary() throws -> LLMUsageSummary {
    try db.read { db in
      var summary = LLMUsageSummary()
      let rows = try Row.fetchCursor(db, sql: "SELECT status, usage_receipt FROM llm_calls")
      while let row = try rows.next() {
        guard let json: String = row["usage_receipt"],
          let receipt = try? JSONDecoder().decode(LLMUsageReceipt.self, from: Data(json.utf8))
        else { continue }
        let status: String = row["status"]
        // A network failure without usage is not evidence of a billable call.
        if status == "success" || receipt.costUSD != nil
          || receipt.inputTokens != nil || receipt.outputTokens != nil
        {
          summary.include(receipt)
        }
      }
      return summary
    }
  }


}
