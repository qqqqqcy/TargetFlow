//
//  AnalysisManager.swift
//  Dayflow
//
//  Re‑written 2025‑05‑07 to use the new `GeminiServicing.processBatch` API.
//  • Drops the per‑chunk URL plumbing – the service handles stitching/encoding.
//  • Still handles batching logic + DB status updates.
//
import Combine
import Foundation
import GRDB

final class AnalysisManager: ObservableObject {
  static let shared = AnalysisManager()

  /// Estimated time when enough screenshots will be collected for the next card.
  /// Provider processing time is not included.
  @Published private(set) var nextCardAnalysisDate: Date?

  private init() {
    store = StorageManager.shared
    llmService = LLMService.shared
  }

  private let store: any StorageManaging
  private let llmService: any LLMServicing

  // Video Processing Constants - removed old summary generation

  private let checkInterval: TimeInterval = 60  // every minute
  private let maxLookback: TimeInterval = 24 * 60 * 60  // only last 24h
  // Note: target batch duration and max gap are controlled via llmService.batchingConfig.

  private var analysisTimer: Timer?
  private var isProcessing = false
  private let queue = DispatchQueue(label: "com.dayflow.geminianalysis.queue", qos: .utility)

  // Automatic catch-up: after any batch succeeds, failed batches from the last
  // 24 hours are retried one at a time. The three properties below are only
  // touched on `queue`.
  private let maxAutomaticRetriesPerBatch = 3
  private var automaticRetryCounts: [Int64: Int] = [:]
  private var isCatchingUpFailedBatches = false
  private var isManualRetryRunning = false

  // Batches the LLM is working on right now. The saved "processing" status
  // can't answer that: it is left behind when the app quits mid-run.
  private let inFlightLock = NSLock()
  private var inFlightBatchIds = Set<Int64>()

  func isBatchInFlight(_ batchId: Int64) -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    return inFlightBatchIds.contains(batchId)
  }

  private func setBatchInFlight(_ batchId: Int64, _ isInFlight: Bool) {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    if isInFlight {
      inFlightBatchIds.insert(batchId)
    } else {
      inFlightBatchIds.remove(batchId)
    }
    queue.async { [weak self] in self?.updateNextCardAnalysisDate() }
  }

  func startAnalysisJob() {
    stopAnalysisJob()  // ensure single timer
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.analysisTimer = Timer.scheduledTimer(
        timeInterval: self.checkInterval,
        target: self,
        selector: #selector(self.timerFired),
        userInfo: nil,
        repeats: true)
      self.triggerAnalysisNow()  // immediate run
    }
  }

  func stopAnalysisJob() {
    analysisTimer?.invalidate()
    analysisTimer = nil
  }

  func triggerAnalysisNow() {
    queue.async { [weak self] in self?.processRecordings() }
  }

  func reprocessBatch(
    _ batchId: Int64, stepHandler: @escaping (LLMProcessingStep) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async {
          completion(
            .failure(
              NSError(
                domain: "AnalysisManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"])))
        }
        return
      }

      // Reset batch state and clear observations
      self.store.deleteObservations(forBatchIds: [batchId])
      let resetBatchIds = Set(self.store.resetBatchStatuses(forBatchIds: [batchId]))
      guard resetBatchIds.contains(batchId) else {
        DispatchQueue.main.async {
          completion(
            .failure(
              NSError(
                domain: "AnalysisManager", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No eligible batches found to reprocess"])))
        }
        return
      }

      self.queueLLMRequest(
        batchId: batchId,
        progressHandler: stepHandler,
        completion: { result in
          DispatchQueue.main.async {
            completion(result)
          }
        }
      )
    }
  }

  /// The Retry button's queue calls this so the automatic catch-up never
  /// reprocesses batches at the same time as a manual retry.
  func setManualRetryRunning(_ isRunning: Bool) {
    queue.async { [weak self] in
      self?.isManualRetryRunning = isRunning
    }
  }

  @objc private func timerFired() { triggerAnalysisNow() }

  // MARK: - Automatic catch-up of failed batches

  /// A batch just succeeded, so the provider works again. Retry what failed
  /// earlier so the user doesn't have to press Retry.
  private func catchUpFailedBatchesAfterSuccess() {
    queue.async { [weak self] in
      guard let self else { return }
      guard !self.isCatchingUpFailedBatches, !self.isManualRetryRunning else { return }

      let batchIds = self.failedBatchIdsToRetryAutomatically()
      guard !batchIds.isEmpty else { return }

      self.isCatchingUpFailedBatches = true
      print("🔁 [AnalysisManager] Catching up \(batchIds.count) failed batches: \(batchIds)")
      self.retryFailedBatch(at: 0, in: batchIds)
    }
  }

  /// Runs on `queue`. Retries one batch, then the next, and stops at the first
  /// failure: if one fails the provider is likely broken again, so the rest wait
  /// for the next success.
  private func retryFailedBatch(at index: Int, in batchIds: [Int64]) {
    guard index < batchIds.count, !isManualRetryRunning else {
      isCatchingUpFailedBatches = false
      return
    }

    // Re-check each batch: while the chain runs, newer batches can succeed and
    // replace this batch's failed card, and retrying it would then write
    // overlapping cards.
    let batchId = batchIds[index]
    guard failedBatchIdsToRetryAutomatically().contains(batchId) else {
      retryFailedBatch(at: index + 1, in: batchIds)
      return
    }
    automaticRetryCounts[batchId, default: 0] += 1

    reprocessBatch(batchId, stepHandler: { _ in }) { [weak self] result in
      guard let self else { return }
      let succeeded: Bool
      if case .success = result { succeeded = true } else { succeeded = false }

      self.queue.async {
        if succeeded {
          self.automaticRetryCounts[batchId] = nil
          self.retryFailedBatch(at: index + 1, in: batchIds)
        } else {
          self.isCatchingUpFailedBatches = false
        }
      }
    }
  }

  /// Failed batches from the last 24 hours that still show a failed card with
  /// recordings behind it, oldest first, skipping any that already used up
  /// their automatic tries. A batch left in "processing" by a quit mid-retry
  /// counts as failed; one the LLM is working on right now does not.
  private func failedBatchIdsToRetryAutomatically(now: Date = Date()) -> [Int64] {
    let cutoff = Int(now.timeIntervalSince1970 - maxLookback)
    let recentFailedBatches = store.allBatches()
      .filter { $0.status == "failed" || $0.status == "processing" }
      .filter { $0.start >= cutoff && !isBatchInFlight($0.id) }
      .filter { automaticRetryCounts[$0.id, default: 0] < maxAutomaticRetriesPerBatch }
      .sorted { $0.start < $1.start }
    guard !recentFailedBatches.isEmpty else { return [] }

    // Only batches whose failed card is still on the timeline. A later batch's
    // cards can replace an older failed card, and retrying that batch would
    // write overlapping cards.
    let days = Set([
      now.getDayInfoFor4AMBoundary().dayString,
      now.addingTimeInterval(-maxLookback).getDayInfoFor4AMBoundary().dayString,
    ])
    var retryableBatchIds = Set<Int64>()
    for day in days {
      for card in store.fetchTimelineCards(forDay: day)
      where TimelineActivityLoader.isRetryableFailedCard(card, storageManager: store) {
        if let batchId = card.batchId {
          retryableBatchIds.insert(batchId)
        }
      }
    }

    return recentFailedBatches.map(\.id).filter { retryableBatchIds.contains($0) }
  }

  private func processRecordings() {
    guard !isProcessing else { return }
    isProcessing = true
    defer { isProcessing = false }

    // 1. Gather unprocessed screenshots
    let screenshots = fetchUnprocessedScreenshots()
    // 2. Build logical batches (duration based on provider config)
    let batches = createScreenshotBatches(from: screenshots)
    // 3. Persist batch rows & join table
    let batchIDs = batches.compactMap(saveScreenshotBatch)
    // 4. Fire LLM for each batch
    for id in batchIDs { queueLLMRequest(batchId: id) }
    updateNextCardAnalysisDate()
  }

  private func updateNextCardAnalysisDate() {
    inFlightLock.lock()
    let hasInFlightBatch = !inFlightBatchIds.isEmpty
    inFlightLock.unlock()

    let config = llmService.batchingConfig
    let screenshots = fetchUnprocessedScreenshots().sorted { $0.capturedAt < $1.capturedAt }
    var batchStart = screenshots.first?.capturedAt
    for (previous, current) in zip(screenshots, screenshots.dropFirst()) {
      if TimeInterval(current.capturedAt - previous.capturedAt) > config.maxGap {
        batchStart = current.capturedAt
      }
    }
    let nextDate = hasInFlightBatch ? nil : batchStart.map {
      Date(timeIntervalSince1970: TimeInterval($0) + config.targetDuration)
    }
    DispatchQueue.main.async {
      self.nextCardAnalysisDate = nextDate
    }
  }

  private func queueLLMRequest(
    batchId: Int64,
    progressHandler: ((LLMProcessingStep) -> Void)? = nil,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    let screenshotsInBatch = store.screenshotsForBatch(batchId)

    guard !screenshotsInBatch.isEmpty else {
      print("Warning: Batch \(batchId) has no screenshots. Marking as 'failed_empty'.")
      self.updateBatchStatus(batchId: batchId, status: "failed_empty")
      completion?(.success(()))
      return
    }

    let itemCount = screenshotsInBatch.count
    let totalDurationSeconds: TimeInterval
    if let first = screenshotsInBatch.first, let last = screenshotsInBatch.last {
      totalDurationSeconds = TimeInterval(last.capturedAt - first.capturedAt)
    } else {
      totalDurationSeconds = 0
    }

    if itemCount == 0 {
      print("Warning: Batch \(batchId) has no data. Marking as 'failed_empty'.")
      self.updateBatchStatus(batchId: batchId, status: "failed_empty")
      completion?(.success(()))
      return
    }

    let minimumDurationSeconds = ScreenshotBatcher.minimumDuration

    if totalDurationSeconds < minimumDurationSeconds {
      print(
        "Batch \(batchId) duration (\(totalDurationSeconds)s) is less than \(minimumDurationSeconds)s. Marking as 'skipped_short'."
      )
      self.updateBatchStatus(batchId: batchId, status: "skipped_short")
      completion?(.success(()))
      return
    }

    if let idleAssessment = IdleBatchClassifier.assess(screenshotsInBatch) {
      let didPersistIdleCard = handleIdleBatch(
        batchId: batchId,
        screenshots: screenshotsInBatch,
        assessment: idleAssessment
      )
      if didPersistIdleCard {
        completion?(.success(()))
        return
      }

      print("Idle shortcut fallback for batch \(batchId); continuing with normal LLM processing.")
    }

    // Start performance tracking for batch processing

    // Add breadcrumb for batch processing start

    setBatchInFlight(batchId, true)
    updateBatchStatus(batchId: batchId, status: "processing")

    llmService.processBatch(batchId, progressHandler: progressHandler) {
      [weak self] (result: Result<ProcessedBatchResult, Error>) in
      guard let self else { return }
      self.setBatchInFlight(batchId, false)

      let now = Date()
      let currentDayInfo = now.getDayInfoFor4AMBoundary()
      let currentLogicalDayString = currentDayInfo.dayString
      print("Processing batch \(batchId) for logical day: \(currentLogicalDayString)")

      switch result {
      case .success(let processedResult):
        let activityCards = processedResult.cards
        let cardIds = processedResult.cardIds
        print(
          "LLM succeeded for Batch \(batchId). Processing \(activityCards.count) activity cards for day \(currentLogicalDayString)."
        )

        // Finish performance transaction - LLM processing completed successfully

        // Debug: Check for duplicate cards from LLM
        print("\n🔍 DEBUG: Checking for duplicate cards from LLM:")
        for (i, card1) in activityCards.enumerated() {
          for (j, card2) in activityCards.enumerated() where j > i {
            if card1.startTime == card2.startTime && card1.endTime == card2.endTime
              && card1.title == card2.title
            {
              print(
                "⚠️ DEBUG: Found duplicate cards at indices \(i) and \(j): '\(card1.title)' [\(card1.startTime) - \(card1.endTime)]"
              )
            }
          }
        }
        print("✅ DEBUG: Duplicate check complete\n")

        // Mark batch as completed immediately
        self.updateBatchStatus(batchId: batchId, status: "completed")
        Task { @MainActor in
          TargetStore.shared.enqueue(cardIDs: cardIds)
        }

        completion?(.success(()))
        self.catchUpFailedBatchesAfterSuccess()

      case .failure(let err):
        print(
          "LLM failed for Batch \(batchId). Day \(currentLogicalDayString) may have been cleared. Error: \(err.localizedDescription)"
        )

        // Finish performance transaction - LLM processing failed

        self.markBatchFailed(batchId: batchId, reason: err.localizedDescription)
        completion?(.failure(err))
      }
    }
  }

  private func markBatchFailed(batchId: Int64, reason: String) {
    store.markBatchFailed(batchId: batchId, reason: reason)
  }

  private func updateBatchStatus(batchId: Int64, status: String) {
    store.updateBatchStatus(batchId: batchId, status: status)
  }

  // MARK: - Screenshot-based Batching

  private func fetchUnprocessedScreenshots() -> [Screenshot] {
    let oldest = Int(Date().timeIntervalSince1970) - Int(maxLookback)
    return store.fetchUnprocessedScreenshots(since: oldest)
  }

  private func createScreenshotBatches(from screenshots: [Screenshot]) -> [ScreenshotBatch] {
    let config = llmService.batchingConfig
    return ScreenshotBatcher.batches(
      from: screenshots, targetDuration: config.targetDuration, maxGap: config.maxGap)

  }

  private func saveScreenshotBatch(_ batch: ScreenshotBatch) -> Int64? {
    let ids = batch.screenshots.map { $0.id }
    return store.saveBatchWithScreenshots(
      startTs: batch.start, endTs: batch.end, screenshotIds: ids)
  }

  private func handleIdleBatch(
    batchId: Int64,
    screenshots: [Screenshot],
    assessment: IdleBatchAssessment
  ) -> Bool {
    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    guard let first = ordered.first, let last = ordered.last else {
      return false
    }

    let batchStart = first.capturedDate

    // Card times are whole minutes, matching the "h:mm a" strings shown on the card.
    let previousCard = store.fetchTimelineCardEndingLast(
      startingBefore: batchStart, excludingBatchId: batchId)
    let mergeCandidate = previousCard.flatMap { idleMergeCandidate($0, batchStart: batchStart) }
    let mergeGapSeconds = mergeCandidate.map { max(0, first.capturedAt - $0.endTs) }
    let cardEndTs = flooredToMinute(last.capturedAt)
    // A new idle card starts where the previous card ends, so a real activity card keeps
    // the minute they would otherwise share.
    let cardStartTs =
      mergeCandidate?.startTs
      ?? max(flooredToMinute(first.capturedAt), previousCard?.endTs ?? 0)
    guard cardEndTs > cardStartTs else {
      return false
    }
    let cardStart = Date(timeIntervalSince1970: TimeInterval(cardStartTs))

    let idleMetadata = IdleCardMetadata(
      classifierVersion: assessment.classifierVersion,
      inputCoverageRatio: assessment.coverageRatio,
      coveredSeconds: assessment.coveredSeconds,
      batchDurationSeconds: assessment.batchDurationSeconds,
      largestUncoveredGapSeconds: assessment.largestUncoveredGapSeconds,
      screenshotCount: assessment.screenshotCount,
      sampledIdleScreenshotCount: assessment.sampledIdleScreenshotCount,
      averageIdleSecondsAtCapture: assessment.averageIdleSecondsAtCapture,
      maxIdleSecondsAtCapture: assessment.maxIdleSecondsAtCapture,
      mergedWithPreviousIdle: mergeCandidate != nil,
      mergeGapSeconds: mergeGapSeconds,
      skippedLLM: true
    )

    let idleCard = IdleBatchClassifier.makeIdleCard(
      from: cardStart,
      to: Date(timeIntervalSince1970: TimeInterval(cardEndTs)),
      metadata: idleMetadata
    )
    // Only this batch's own earlier cards are removed; other batches' cards are never touched.
    let (savedCardId, deletedVideoPaths) = store.saveIdleBatchCard(
      idleCard,
      startTs: cardStartTs,
      endTs: cardEndTs,
      batchId: batchId,
      extendingCardId: mergeCandidate?.id
    )

    guard let savedCardId else {
      return false
    }

    for path in deletedVideoPaths {
      let url = URL(fileURLWithPath: path)
      try? FileManager.default.removeItem(at: url)
    }

    Task { @MainActor in
      TargetStore.shared.enqueue(cardIDs: [savedCardId])
    }
    StorageManager.shared.updateBatch(batchId, status: "analyzed", reason: "idle_shortcut_applied")
    StorageManager.shared.checkpoint(mode: .passive)

    return true
  }

  /// The previous card, if it's an idle card this batch should extend instead of adding a new one.
  /// The gap can be negative when the previous card's end was rounded up past the batch start.
  private func idleMergeCandidate(_ previousCard: TimelineCardWithTimestamps, batchStart: Date)
    -> TimelineCardWithTimestamps?
  {
    let batchDay = batchStart.getDayInfoFor4AMBoundary().dayString
    let gapSeconds = Int(batchStart.timeIntervalSince1970) - previousCard.endTs
    guard
      gapSeconds < IdleBatchRules.mergeGapSeconds,
      previousCard.day == batchDay,
      normalizedIdleValue(previousCard.category) == "idle",
      normalizedIdleValue(previousCard.title) == "idle"
    else {
      return nil
    }

    return previousCard
  }

  private func flooredToMinute(_ timestamp: Int) -> Int {
    timestamp - timestamp % 60
  }

  private func normalizedIdleValue(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

}
