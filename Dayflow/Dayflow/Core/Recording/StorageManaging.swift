import Foundation

/// File + database persistence used by screen‑recorder & Gemini pipeline.
///
/// _No_ `@MainActor` isolation ⇒ can be called from any thread/actor.
/// If you add UI‑touching methods later, isolate **those** individually.
protocol StorageManaging: Sendable {
  func updateBatchStatus(batchId: Int64, status: String)
  func markBatchFailed(batchId: Int64, reason: String)

  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps?
  func fetchTimelineCardEndingLast(startingBefore: Date, excludingBatchId: Int64)
    -> TimelineCardWithTimestamps?
  func saveIdleBatchCard(
    _ card: TimelineCardShell, startTs: Int, endTs: Int, batchId: Int64, extendingCardId: Int64?
  ) -> (cardId: Int64?, deletedVideoPaths: [String])

  // Timeline Queries
  func fetchTimelineCards(forDay day: String) -> [TimelineCard]
  func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard]
  // Daily goals
  func fetchMostRecentDayGoalPlan(beforeOrOn day: String) -> DayGoalPlan?
  func saveDayGoalPlan(_ plan: DayGoalPlan)

  // Reprocessing Methods
  func deleteObservations(forBatchIds batchIds: [Int64])
  func resetBatchStatuses(forBatchIds batchIds: [Int64]) -> [Int64]

  /// All batches, newest first
  func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)]

  // MARK: - Screenshot Management (new - replaces video chunks)

  /// Fetch screenshots that haven't been assigned to a batch yet
  func fetchUnprocessedScreenshots(since oldestTimestamp: Int) -> [Screenshot]

  /// Create a batch from screenshots, returns batch ID
  func saveBatchWithScreenshots(startTs: Int, endTs: Int, screenshotIds: [Int64]) -> Int64?

  /// Screenshots that belong to one batch, sorted by capture time
  func screenshotsForBatch(_ batchId: Int64) -> [Screenshot]

  /// Fetch screenshots within a time range (for timelapse generation)
  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int) -> [Screenshot]
}
