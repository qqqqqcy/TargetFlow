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

  init(
    store: any StorageManaging = StorageManager.shared,
    llmService: any LLMServicing = LLMService.shared,
    evidenceCaptureStartTs: Int = Int(Date().timeIntervalSince1970) + 1,
    idlePixels: @escaping (Screenshot) -> [UInt8]? = IdleBatchClassifier.screenPixels,
    evaluate: @escaping @MainActor ([Int64]) -> Void = { TargetStore.shared.enqueue(cardIDs: $0) }
  ) {
    self.store = store
    self.llmService = llmService
    self.evidenceCaptureStartTs = evidenceCaptureStartTs
    self.idlePixels = idlePixels
    self.evaluate = evaluate
  }

  private let idlePixels: (Screenshot) -> [UInt8]?
  private let evaluate: @MainActor ([Int64]) -> Void
  private let store: any StorageManaging
  private let llmService: any LLMServicing
  // Migrated screenshots default to false for privacy, so only captures made by this
  // running version provide reliable negative privacy provenance for this shortcut.
  private let evidenceCaptureStartTs: Int

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
  private var attemptedPendingRevisions = Set<String>()
  private var automaticBatchQueue: [Int64] = []
  private var automaticBatchRunning = false

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

      // Observations remain until the replacement transaction commits.
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

    publishPendingAfterSettingChange()
    // 1. Gather unprocessed screenshots
    let screenshots = fetchUnprocessedScreenshots()
    // 2. Build logical batches (duration based on provider config)
    let batches = createScreenshotBatches(from: screenshots)
    // 3. Persist batch rows & join table
    let batchIDs = batches.compactMap(saveScreenshotBatch)
    // Process new batches in capture order so a short suffix can be continued.
    automaticBatchQueue.append(contentsOf: batchIDs)
    runNextAutomaticBatch()
    updateNextCardAnalysisDate()
  }

  private func runNextAutomaticBatch() {
    guard !automaticBatchRunning, !automaticBatchQueue.isEmpty else { return }
    automaticBatchRunning = true
    let id = automaticBatchQueue.removeFirst()
    queueLLMRequest(batchId: id) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        self.automaticBatchRunning = false
        self.publishPendingAfterSettingChange()
        self.runNextAutomaticBatch()
      }
    }
  }

  private func publishPendingAfterSettingChange() {
    let minimum = Int(AnalysisPreferences.interval)
    let eligible = StorageManager.shared.pendingTimelineEvidence().filter {
      $0.endTs - $0.startTs >= minimum && $0.id != nil
    }
    let keys = Set(eligible.compactMap { $0.id.map { "\($0):\(minimum)" } })
    attemptedPendingRevisions.formIntersection(keys)
    for pending in eligible {
      guard let id = pending.id else { continue }
      let key = "\(id):\(minimum)"
      guard attemptedPendingRevisions.insert(key).inserted else { continue }
      Task {
        do {
          let ids = try await LLMService.publishEligiblePending(pending)
          await MainActor.run { self.evaluate(ids) }
        } catch {
          print("Pending event could not be published: \(error.localizedDescription)")
        }
      }
    }
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
      if screenshotsInBatch.contains(where: \.isPrivacyRedacted) {
        // A sealed short fragment cannot support a visible model request, but
        // protected captures still need a separate local pending record.
        setBatchInFlight(batchId, true)
        updateBatchStatus(batchId: batchId, status: "processing")
        Task {
          do {
            try await LLMService.saveShortPrivacyEvidence(batchId: batchId, screenshots: screenshotsInBatch)
            self.setBatchInFlight(batchId, false)
            self.queue.async {
              self.updateBatchStatus(batchId: batchId, status: "skipped_short")
              self.publishPendingAfterSettingChange()
              completion?(.success(()))
            }
          } catch {
            self.setBatchInFlight(batchId, false)
            self.markBatchFailed(batchId: batchId, reason: error.localizedDescription)
            completion?(.failure(error))
          }
        }
      } else {
        print("Batch \(batchId) is a sealed short fragment; retaining raw evidence without a model request.")
        updateBatchStatus(batchId: batchId, status: "skipped_short")
        completion?(.success(()))
      }
      return
    }

    let inactivityThreshold = InactivityPreferences.thresholdSeconds
    let historyStart = (screenshotsInBatch.first?.capturedAt ?? 0)
      - IdleBatchRules.historyLookbackSeconds(thresholdSeconds: inactivityThreshold)
    let history = store.fetchScreenshotsInTimeRange(
      startTs: max(historyStart, evidenceCaptureStartTs),
      endTs: screenshotsInBatch.first?.capturedAt ?? historyStart)
    if let idleAssessment = IdleBatchClassifier.assess(
      screenshotsInBatch, history: history, evidenceSince: evidenceCaptureStartTs,
      thresholdSeconds: inactivityThreshold, pixels: idlePixels)
    {
      for attempt in 0..<3 {
        do {
          let didPersistIdleCard = try handleIdleBatch(
            batchId: batchId, screenshots: screenshotsInBatch, assessment: idleAssessment,
            assessmentHistory: history)
          if didPersistIdleCard {
            completion?(.success(()))
            return
          }
          break
        } catch TimelineCardReplacementError.minimumDurationChanged where attempt < 2 {
          continue
        } catch {
          markBatchFailed(batchId: batchId, reason: error.localizedDescription)
          completion?(.failure(error))
          return
        }
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
          self.evaluate(cardIds)
        }

        completion?(.success(()))
        if processedResult.providerWasUsed { self.catchUpFailedBatchesAfterSuccess() }

      case .failure(let err):
        print(
          "LLM failed for Batch \(batchId). Day \(currentLogicalDayString) may have been cleared. Error: \(err.localizedDescription)"
        )

        // Finish performance transaction - LLM processing failed

        self.markBatchFailed(batchId: batchId, reason: err.localizedDescription)
        if (err as? TimelineCardReplacementError) != .sourceEvidenceChanged {
          self.queue.async { self.publishPendingAfterSettingChange() }
        }
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
    let first = screenshots.min { $0.capturedAt < $1.capturedAt }
    var continuingFrom: Int?
    if let first {
      let history = store.fetchScreenshotsInTimeRange(startTs: first.capturedAt - 720, endTs: first.capturedAt - 1)
      if let previous = history.last,
        TimelineEvidencePolicy.captureContinues(history: history, next: first,
          recordedContinuity: TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: first.capturedAt),
          privacy: first.isPrivacyRedacted),
        let pending = StorageManager.shared.pendingTimelineEvidence().last(where: {
          ($0.card.evidenceKind == .privacyRedacted) == first.isPrivacyRedacted
            && $0.endTs == previous.capturedAt && $0.lastScreenshotId == previous.id
            && Date(timeIntervalSince1970: Double($0.startTs)).getDayInfoFor4AMBoundary().dayString
              == first.capturedDate.getDayInfoFor4AMBoundary().dayString
        }) {
        continuingFrom = pending.startTs
      }
    }
    return ScreenshotBatcher.batches(
      from: screenshots, targetDuration: config.targetDuration, maxGap: config.maxGap,
      continuingFrom: continuingFrom)

  }

  private func saveScreenshotBatch(_ batch: ScreenshotBatch) -> Int64? {
    let ids = batch.screenshots.map { $0.id }
    return store.saveBatchWithScreenshots(
      startTs: batch.start, endTs: batch.end, screenshotIds: ids)
  }

  private func handleIdleBatch(
    batchId: Int64,
    screenshots: [Screenshot],
    assessment: IdleBatchAssessment,
    assessmentHistory: [Screenshot]
  ) throws -> Bool {
    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    guard let first = ordered.first, let last = ordered.last else {
      return false
    }

    let batchStart = first.capturedDate

    // Keep capture boundaries exact; clock labels are formatted separately.
    let previousCard = store.fetchTimelineCardEndingLast(
      startingBefore: batchStart, excludingBatchId: batchId)
    let cardEndTs = last.capturedAt
    let history = store.fetchScreenshotsInTimeRange(
      startTs: max(first.capturedAt - 720, evidenceCaptureStartTs), endTs: first.capturedAt - 1)
    let mergeCandidate = previousCard.flatMap { card in
      Self.canExtendIdle(card, first: first, history: history, endTs: cardEndTs) ? card : nil
    }
    let continuous = history.last.map { previous in
      TimelineEvidencePolicy.captureContinues(history: history, next: first,
        recordedContinuity: TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: first.capturedAt))
    } ?? false
    let pending = continuous ? StorageManager.shared.pendingTimelineEvidence().last { item in
      item.card.evidenceKind == .inputInactive && item.endTs == history.last?.capturedAt
        && item.lastScreenshotId == history.last?.id
        && Date(timeIntervalSince1970: Double(item.startTs)).getDayInfoFor4AMBoundary().dayString
          == first.capturedDate.getDayInfoFor4AMBoundary().dayString
        && cardEndTs - item.startTs <= 3600
    } : nil
    let mergeGapSeconds = mergeCandidate.map { max(0, first.capturedAt - $0.endTs) }
    let cardStartTs = min(pending?.startTs ?? first.capturedAt,
      mergeCandidate?.startTs ?? first.capturedAt)
    guard cardEndTs > cardStartTs, cardEndTs - cardStartTs <= 3600,
      Date(timeIntervalSince1970: Double(cardStartTs)).getDayInfoFor4AMBoundary().dayString
        == Date(timeIntervalSince1970: Double(cardEndTs - 1)).getDayInfoFor4AMBoundary().dayString else {
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
      skippedLLM: true,
      inactivityThresholdSeconds: assessment.thresholdSeconds
    )

    let idleCard = IdleBatchClassifier.makeIdleCard(
      from: cardStart,
      to: Date(timeIntervalSince1970: TimeInterval(cardEndTs)),
      metadata: idleMetadata
    )
    let sourceFrames = store.fetchScreenshotsInTimeRange(startTs: cardStartTs, endTs: cardEndTs)
    guard let firstSource = sourceFrames.first, let lastSource = sourceFrames.last else { return false }
    let requiredSources = Array(Set((screenshots + assessmentHistory + sourceFrames).map(\.id)
      + (pending?.sourceScreenshotIds ?? [])))
    let oldPending = StorageManager.shared.pendingTimelineEvidence().filter { $0.batchId == batchId }
    let consumedIds = Array(Set(oldPending.compactMap(\.id) + [pending?.id].compactMap { $0 }))
    let cardData = ActivityCardData(startTime: idleCard.startTimestamp, endTime: idleCard.endTimestamp,
      category: idleCard.category, subcategory: idleCard.subcategory, title: idleCard.title,
      summary: idleCard.summary, detailedSummary: idleCard.detailedSummary,
      distractions: nil, appSites: nil, evidenceKind: .inputInactive)
    if cardEndTs - cardStartTs < Int(AnalysisPreferences.interval) {
      let candidate = PendingTimelineEvidence(id: nil, batchId: batchId, startTs: cardStartTs,
        endTs: cardEndTs, card: cardData, firstScreenshotId: firstSource.id, lastScreenshotId: lastSource.id,
      sourceScreenshotIds: Array(Set(requiredSources + (pending?.sourceScreenshotIds ?? []))))
      _ = try StorageManager.shared.replaceTimelineCardGroups([], batchId: batchId,
        keepingNewerBatchesCardsStartingAfter: batchStart,
        pendingToSave: [candidate], pendingToDelete: consumedIds, markBatchAnalyzed: true,
        replacementObservations: [], requiredScreenshotIds: requiredSources,
        requiredPendingIds: [pending?.id].compactMap { $0 })
      StorageManager.shared.updateBatch(batchId, status: "analyzed", reason: "idle_pending")
      return true
    }
    let shell = TimelineCardShell(startTimestamp: idleCard.startTimestamp, endTimestamp: idleCard.endTimestamp,
      category: idleCard.category, subcategory: idleCard.subcategory, title: idleCard.title,
      summary: idleCard.summary, detailedSummary: idleCard.detailedSummary, distractions: nil, appSites: nil,
      idleMetadata: idleMetadata, evidenceKind: .inputInactive, exactStartTs: cardStartTs, exactEndTs: cardEndTs)
    let saved = try StorageManager.shared.replaceTimelineCardGroups([
      TimelineCardReplacementGroup(from: Date(timeIntervalSince1970: Double(cardStartTs)),
        to: Date(timeIntervalSince1970: Double(cardEndTs)), cards: [shell])],
      batchId: batchId, keepingNewerBatchesCardsStartingAfter: batchStart,
      pendingToDelete: consumedIds, enforceMinimum: true, markBatchAnalyzed: true,
      replacementObservations: [], requiredScreenshotIds: requiredSources,
      requiredPendingIds: [pending?.id].compactMap { $0 })
    guard let savedCardId = saved.insertedIds.first else { return false }
    let deletedVideoPaths = saved.deletedVideoPaths

    for path in deletedVideoPaths {
      let url = URL(fileURLWithPath: path)
      try? FileManager.default.removeItem(at: url)
    }

    Task { @MainActor in
      self.evaluate([savedCardId])
    }
    StorageManager.shared.updateBatch(batchId, status: "analyzed", reason: "idle_shortcut_applied")
    StorageManager.shared.checkpoint(mode: .passive)

    return true
  }

  /// Extend only the same proven evidence type and a supported capture chain.
  static func canExtendIdle(_ previous: TimelineCardWithTimestamps, first: Screenshot,
    history: [Screenshot], endTs: Int) -> Bool {
    let firstMinute = first.capturedAt - first.capturedAt % 60
    let day = first.capturedDate.getDayInfoFor4AMBoundary().dayString
    let normalizedCategory = previous.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedTitle = previous.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return (previous.endTs == firstMinute || previous.endTs == history.last?.capturedAt) && previous.day == day
      && previous.evidenceKind == .inputInactive && normalizedCategory == "idle" && normalizedTitle == "idle"
      && endTs > previous.endTs && endTs - previous.startTs <= 3600
      && Date(timeIntervalSince1970: Double(endTs - 1)).getDayInfoFor4AMBoundary().dayString == day
      && TimelineEvidencePolicy.captureContinues(history: history, next: first,
        recordedContinuity: history.last.flatMap {
          TimelineCaptureBoundaries.shared.continuity(from: $0.capturedAt, to: first.capturedAt)
        })
  }


}
