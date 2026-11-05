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
  @Published private(set) var liveBatchIsQueued = false
  @Published private(set) var liveBatchIsAnalyzing = false
  @Published private(set) var isRecoveringEarlierBatches = false
  /// Duration in seconds of the latest recent pending event, only while below
  /// the current minimum. This is analyzed evidence, not an active model call.
  @Published private(set) var latestPendingEventDuration: TimeInterval?

  init(
    store: any StorageManaging = StorageManager.shared,
    llmService: any LLMServicing = LLMService.shared,
    evidenceCaptureStartTs: Int = Int(Date().timeIntervalSince1970) + 1,
    idlePixels: @escaping (Screenshot) -> [UInt8]? = IdleBatchClassifier.screenPixels,
    now: @escaping () -> Date = Date.init,
    pendingEvidence: @escaping () -> [PendingTimelineEvidence] = {
      StorageManager.shared.pendingTimelineEvidence()
    },
    evaluate: @escaping @MainActor ([Int64]) -> Void = { TargetStore.shared.enqueue(cardIDs: $0) }
  ) {
    self.store = store
    self.llmService = llmService
    self.evidenceCaptureStartTs = evidenceCaptureStartTs
    self.idlePixels = idlePixels
    self.now = now
    self.pendingEvidence = pendingEvidence
    self.evaluate = evaluate
  }

  private let idlePixels: (Screenshot) -> [UInt8]?
  private let now: () -> Date
  private let pendingEvidence: () -> [PendingTimelineEvidence]
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

  // Live work and recovery each have one slot. Live batches stay in capture
  // order; manual and automatic retries share the recovery slot.
  // All scheduler state is confined to `queue`.
  private let maxAutomaticRetriesPerBatch = 3
  private var automaticRetryCounts: [Int64: Int] = [:]
  private var automaticRetryDates: [Int64: Date] = [:]
  private var nextCatchUpDate = Date.distantPast
  private var catchUpEnabled = false
  private var liveRunningBatch: Int64?
  private var catchUpRunningBatch: Int64?
  private var manualRetryQueue: [(id: Int64, progress: (LLMProcessingStep) -> Void,
    completion: (Result<Void, Error>) -> Void)] = []
  private var isManualRetryRunning = false
  private var attemptedPendingRevisions = Set<String>()
  private var automaticBatchQueue: [Int64] = []

  // Batches reserved by a lane, including queued manual retries. The saved
  // "processing" status can also be left behind when the app quits mid-run.
  private let inFlightLock = NSLock()
  private var inFlightBatchIds = Set<Int64>()

  func isBatchInFlight(_ batchId: Int64) -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    return inFlightBatchIds.contains(batchId)
  }

  private func claimBatch(_ batchId: Int64) -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    return inFlightBatchIds.insert(batchId).inserted
  }

  private func releaseBatch(_ batchId: Int64) {
    inFlightLock.lock()
    inFlightBatchIds.remove(batchId)
    inFlightLock.unlock()
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

      // Never reset an active or already scheduled batch back to pending.
      guard !self.automaticBatchQueue.contains(batchId), self.claimBatch(batchId) else {
        DispatchQueue.main.async { completion(.failure(Self.batchAlreadyScheduledError)) }
        return
      }

      // Reserve before enqueueing; reset only when the shared retry lane is free.
      self.manualRetryQueue.append((batchId, stepHandler, { result in
        DispatchQueue.main.async { completion(result) }
      }))
      self.runNextAutomaticBatch()
    }
  }

  /// Pause new historical attempts while the Retry button's queue runs.
  /// An already running attempt is not interrupted; live work still has priority.
  func setManualRetryRunning(_ isRunning: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      self.isManualRetryRunning = isRunning
      if !isRunning { self.runNextAutomaticBatch() }
    }
  }

  @objc private func timerFired() { triggerAnalysisNow() }

  // MARK: - Automatic catch-up of failed batches

  private static var batchAlreadyScheduledError: NSError {
    NSError(domain: "AnalysisManager", code: 5,
      userInfo: [NSLocalizedDescriptionKey: "Batch is already scheduled or processing"])
  }

  private static func isTimelineConflict(_ result: Result<Void, Error>) -> Bool {
    guard case .failure(let error) = result else { return false }
    return (error as? TimelineCardReplacementError) == .timelineChanged
  }

  /// Retry failed-card batches and uncommitted timeline conflicts with active
  /// source screenshots, least-attempted then oldest first. Both paths share
  /// the 24-hour window, attempt budget and cooldowns. Orphaned "processing"
  /// batches still require a failed card.
  private func failedBatchIdsToRetryAutomatically(now: Date) -> [Int64] {
    let cutoff = Int(now.timeIntervalSince1970 - maxLookback)
    let recentFailedBatches = store.allBatches()
      .filter { $0.status == "failed" || $0.status == "processing"
        || $0.status == "pending_conflict" }
      .filter { $0.start >= cutoff && !isBatchInFlight($0.id) }
      .filter { automaticRetryCounts[$0.id, default: 0] < maxAutomaticRetriesPerBatch }
      .filter { (automaticRetryDates[$0.id] ?? .distantPast) <= now }
      // Untouched failures get a turn before repeating an older bad reply.
      .sorted {
        let lhs = automaticRetryCounts[$0.id, default: 0]
        let rhs = automaticRetryCounts[$1.id, default: 0]
        return lhs == rhs ? $0.start < $1.start : lhs < rhs
      }
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

    return recentFailedBatches.filter { batch in
      if batch.status == "pending_conflict" {
        return store.screenshotsForBatch(batch.id).contains { !$0.isDeleted }
      }
      return retryableBatchIds.contains(batch.id)
    }.map(\.id)
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
    if liveRunningBatch == nil {
      while !automaticBatchQueue.isEmpty {
        let id = automaticBatchQueue.removeFirst()
        guard claimBatch(id) else { continue }
        liveRunningBatch = id
        queueLLMRequest(batchId: id) { [weak self] result in
          guard let self else { return }
          self.queue.async {
            self.liveRunningBatch = nil
            if !Self.isTimelineConflict(result) { self.publishPendingAfterSettingChange() }
            self.runNextAutomaticBatch()
          }
        }
        break
      }
    }
    runNextRetryBatch()
    updateNextCardAnalysisDate()
  }

  private func runNextRetryBatch() {
    guard catchUpRunningBatch == nil else { return }
    let id: Int64
    let isCatchUp: Bool
    let progress: ((LLMProcessingStep) -> Void)?
    let completion: ((Result<Void, Error>) -> Void)?
    if !manualRetryQueue.isEmpty {
      let request = manualRetryQueue.removeFirst()
      id = request.id  // Already claimed when queued.
      isCatchUp = false
      progress = request.progress
      completion = request.completion
    } else {
      let date = now()
      guard catchUpEnabled, !isManualRetryRunning, date >= nextCatchUpDate,
        let candidate = failedBatchIdsToRetryAutomatically(now: date).first,
        !automaticBatchQueue.contains(candidate), claimBatch(candidate) else { return }
      id = candidate
      isCatchUp = true
      progress = nil
      completion = nil
    }
    catchUpRunningBatch = id
    // Observations remain until the replacement transaction commits. Claiming
    // before resetting also reserves manual requests waiting for this lane.
    guard store.resetBatchStatuses(forBatchIds: [id]).contains(id) else {
      releaseBatch(id)
      catchUpRunningBatch = nil
      completion?(.failure(NSError(domain: "AnalysisManager", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No eligible batches found to reprocess"])))
      if !isCatchUp {
        queue.async { [weak self] in self?.runNextAutomaticBatch() }
      }
      return
    }
    if isCatchUp { automaticRetryCounts[id, default: 0] += 1 }
    queueLLMRequest(batchId: id, isCatchUp: isCatchUp, progressHandler: progress) { [weak self] result in
      guard let self else { return }
      self.queue.async {
        self.catchUpRunningBatch = nil
        if isCatchUp {
          let date = self.now()
          self.nextCatchUpDate = date.addingTimeInterval(60)
          self.automaticRetryDates[id] = date.addingTimeInterval(
            60 * pow(2, Double(self.automaticRetryCounts[id, default: 1] - 1)))
          if case .failure(let error) = result, !Self.isTimelineConflict(result),
            !TimelineRetryPolicy.canContinueQueue(after: error) {
            self.catchUpEnabled = false
          }
        }
        completion?(result)
        if !Self.isTimelineConflict(result) { self.publishPendingAfterSettingChange() }
        self.runNextAutomaticBatch()
      }
    }
  }

  private func publishPendingAfterSettingChange() {
    let minimum = Int(AnalysisPreferences.interval)
    let eligible = pendingEvidence().filter {
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
    let liveRunning = liveRunningBatch != nil
    let retryRunning = catchUpRunningBatch != nil
    let queued = !automaticBatchQueue.isEmpty
    let config = llmService.batchingConfig
    let screenshots = fetchUnprocessedScreenshots().sorted { $0.capturedAt < $1.capturedAt }
    var batchStart = screenshots.first?.capturedAt
    for (previous, current) in zip(screenshots, screenshots.dropFirst()) {
      if TimeInterval(current.capturedAt - previous.capturedAt) > config.maxGap {
        batchStart = current.capturedAt
      }
    }
    let nextDate = batchStart.map {
      Date(timeIntervalSince1970: TimeInterval($0) + config.targetDuration)
    }
    let cutoff = Int(now().timeIntervalSince1970 - maxLookback)
    let pendingDuration = pendingEvidence()
      .filter { $0.endTs >= cutoff && $0.endTs > $0.startTs }
      .max { $0.endTs < $1.endTs }
      .flatMap { item -> TimeInterval? in
        let duration = TimeInterval(item.endTs - item.startTs)
        return duration < AnalysisPreferences.interval ? duration : nil
      }
    DispatchQueue.main.async {
      self.latestPendingEventDuration = pendingDuration
      self.nextCardAnalysisDate = nextDate
      self.liveBatchIsQueued = queued
      self.liveBatchIsAnalyzing = liveRunning
      self.isRecoveringEarlierBatches = retryRunning
    }
  }

  private func queueLLMRequest(
    batchId: Int64,
    isCatchUp: Bool = false,
    progressHandler: ((LLMProcessingStep) -> Void)? = nil,
    completion: ((Result<Void, Error>) -> Void)? = nil
  ) {
    // Both lane schedulers must claim before any reset or execution.
    let finish: (Result<Void, Error>) -> Void = { result in
      self.releaseBatch(batchId)
      completion?(result)
    }
    let screenshotsInBatch = store.screenshotsForBatch(batchId)

    guard !screenshotsInBatch.isEmpty else {
      print("Warning: Batch \(batchId) has no screenshots. Marking as 'failed_empty'.")
      self.updateBatchStatus(batchId: batchId, status: "failed_empty")
      finish(.success(()))
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
      finish(.success(()))
      return
    }

    let minimumDurationSeconds = ScreenshotBatcher.minimumDuration

    if totalDurationSeconds < minimumDurationSeconds {
      print("Batch \(batchId) is a sealed short fragment; retaining raw evidence without a model request.")
      updateBatchStatus(batchId: batchId, status: "skipped_short")
      finish(.success(()))
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
            finish(.success(()))
            return
          }
          break
        } catch TimelineCardReplacementError.minimumDurationChanged where attempt < 2 {
          continue
        } catch {
          markBatchFailed(batchId: batchId, reason: error.localizedDescription)
          finish(.failure(error))
          return
        }
      }

      print("Idle shortcut fallback for batch \(batchId); continuing with normal LLM processing.")
    }

    // Start performance tracking for batch processing

    // Add breadcrumb for batch processing start

    updateBatchStatus(batchId: batchId, status: "processing")

    llmService.processBatch(batchId, progressHandler: progressHandler) {
      [weak self] (result: Result<ProcessedBatchResult, Error>) in
      guard let self else { return }
      self.queue.async {
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

          if processedResult.providerWasUsed && !isCatchUp {
            self.catchUpEnabled = true
          }
          finish(.success(()))

        case .failure(let err):
          print(
            "LLM failed for Batch \(batchId). Day \(currentLogicalDayString) may have been cleared. Error: \(err.localizedDescription)"
          )

          // Finish performance transaction - LLM processing failed

          let isTimelineConflict = (err as? TimelineCardReplacementError) == .timelineChanged
          // Preserve a winning commit. Otherwise retain an explicit recovery
          // state: these screenshots are already batched and have no failed card.
          if isTimelineConflict {
            self.deferTimelineConflict(batchId: batchId)
          } else {
            self.markBatchFailed(batchId: batchId, reason: err.localizedDescription)
            if !TimelineRetryPolicy.canContinueQueue(after: err) {
              self.catchUpEnabled = false
            }
            if (err as? TimelineCardReplacementError) != .sourceEvidenceChanged {
              self.queue.async { self.publishPendingAfterSettingChange() }
            }
          }
          finish(.failure(err))
        }
      }
    }
  }

  private func deferTimelineConflict(batchId: Int64) {
    guard let batch = store.allBatches().first(where: { $0.id == batchId }),
      batch.status != "completed", batch.status != "analyzed" else { return }
    updateBatchStatus(batchId: batchId, status: "pending_conflict")
    catchUpEnabled = true
    let retryDate = now().addingTimeInterval(60)
    nextCatchUpDate = max(nextCatchUpDate, retryDate)
    automaticRetryDates[batchId] = max(automaticRetryDates[batchId] ?? .distantPast, retryDate)
    // Automatic attempts are counted by the retry lane and set their existing
    // exponential backoff on completion; a first live conflict costs no retry.
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
          recordedContinuity: TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: first.capturedAt)),
        let pending = pendingEvidence().last(where: {
          $0.endTs == previous.capturedAt && $0.lastScreenshotId == previous.id
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
    let pending = continuous ? pendingEvidence().last { item in
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
    let oldPending = pendingEvidence().filter { $0.batchId == batchId }
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
      guard AppStoragePaths.canRemoveGeneratedMedia(at: url) else { continue }
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
