//
//  LLMService.swift
//  Dayflow
//

import AppKit
import Combine
import Foundation
import GRDB
import SwiftUI

private final class TimelineCommitGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isHeld {
        waiters.append(continuation)
        lock.unlock()
      } else {
        isHeld = true
        lock.unlock()
        continuation.resume()
      }
    }
  }

  func release() {
    lock.lock()
    let next = waiters.isEmpty ? nil : waiters.removeFirst()
    if next == nil { isHeld = false }
    lock.unlock()
    next?.resume()
  }
}

struct ProcessedBatchResult {
  let cards: [ActivityCardData]
  let cardIds: [Int64]
  let providerWasUsed: Bool
}

enum LLMProcessingStep: Sendable, Equatable {
  case transcribing
  case generatingCards
}

protocol LLMServicing {
  func processBatch(
    _ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)?,
    completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void)
  func generateTargetEvaluation(prompt: String) async throws -> String
  var batchingConfig: BatchingConfig { get }
}

final class LLMService: LLMServicing {
  static let shared: LLMServicing = LLMService()
  private let loadConfiguration: () throws -> AIConfiguration
  private let configuredText: ((String, AIFeature) async throws -> String)?
  private let timelineGeneratorOverride: TimelineEvidencePolicy.Generate?
  private let beforeTimelineCommit: (() -> Void)?

  init(
    loadConfiguration: @escaping () throws -> AIConfiguration = {
      try AIConfigurationStore.shared.load()
    },
    configuredText: ((String, AIFeature) async throws -> String)? = nil,
    timelineGeneratorOverride: TimelineEvidencePolicy.Generate? = nil,
    beforeTimelineCommit: (() -> Void)? = nil
  ) {
    self.loadConfiguration = loadConfiguration
    self.configuredText = configuredText
    self.timelineGeneratorOverride = timelineGeneratorOverride
    self.beforeTimelineCommit = beforeTimelineCommit
  }

  private static let timelineCommitGate = TimelineCommitGate()
  private static let batchClaimLock = NSLock()
  private static var claimedBatches = Set<Int64>()

  /// Publish already generated facts after a settings decrease; serialization and the
  /// conditional pending deletion make this safe against a concurrent batch rewrite.
  static func publishEligiblePending(_ pending: PendingTimelineEvidence, beforeCommit: (() -> Void)? = nil) async throws -> [Int64] {
    await timelineCommitGate.acquire()
    defer { timelineCommitGate.release() }
    guard let id = pending.id, pending.endTs - pending.startTs >= Int(AnalysisPreferences.interval),
      pending.endTs - pending.startTs <= 3600,
      StorageManager.shared.pendingTimelineEvidence().contains(where: { $0.id == id })
    else { return [] }
    let expectedTimeline = try StorageManager.shared.captureTimelineRewriteSnapshot(
      from: pending.startTs, to: pending.endTs + 1)
    guard let current = StorageManager.shared.pendingTimelineEvidence().first(where: { $0.id == id }) else { return [] }
    func facts(_ value: PendingTimelineEvidence) -> [String] {
      let card = value.card
      return [String(value.batchId), String(value.startTs), String(value.endTs),
        String(value.firstScreenshotId), String(value.lastScreenshotId),
        card.startTime, card.endTime, card.category, card.subcategory, card.title,
        card.summary, card.detailedSummary, card.evidenceKind?.rawValue ?? "",
        card.appSites?.primary ?? "", card.appSites?.secondary ?? "",
        TargetStore.distractionJSON(card.distractions)]
    }
    guard facts(current) == facts(pending),
      Set(current.sourceScreenshotIds) == Set(pending.sourceScreenshotIds) else {
      throw TimelineCardReplacementError.timelineChanged
    }
    let recordedSourceIDs = Set(pending.sourceScreenshotIds)
    let sources = StorageManager.shared.fetchScreenshotsInTimeRange(
      startTs: pending.startTs, endTs: pending.endTs).filter {
        recordedSourceIDs.isEmpty || recordedSourceIDs.contains($0.id)
      }
    // Older pending records may predate capture-run planning. A settings change
    // must not publish a card across a stop or an unproven file transition.
    guard sources.first?.id == pending.firstScreenshotId,
      sources.last?.id == pending.lastScreenshotId,
      TimelineEvidencePolicy.captureRuns(sources, recordedContinuity: {
        TimelineCaptureBoundaries.shared.continuity(from: $0, to: $1)
      }).count == 1 else { return [] }
    let sourceIds = sources.map(\.id)
    beforeCommit?()
    let categoryPolicy = TimelineCategoryWritePolicy.current()
    let history = StorageManager.shared.fetchTimelineCardsByTimeRange(
      from: Date(timeIntervalSince1970: Double(pending.startTs)),
      to: Date(timeIntervalSince1970: Double(pending.endTs)))
    // A stored pending fact is unpublished input, not permission to rewrite a
    // disabled event's published history when the duration setting changes.
    guard !history.contains(where: {
      categoryPolicy.isDisabled($0.category)
        && ($0.startTs ?? Int.max) < pending.endTs
        && ($0.endTs ?? Int.min) > pending.startTs
    }) else { return [] }
    let card = pending.card
    let policy = TimelineOutputPolicy()
    let shell = TimelineCardShell(startTimestamp: policy.formatTimestampForPrompt(pending.startTs),
      endTimestamp: policy.formatTimestampForPrompt(pending.endTs / 60 * 60 + 60),
      category: card.category == "System" ? "System"
        : policy.normalizeCategory(card.category, descriptors: categoryPolicy.descriptors),
      subcategory: card.subcategory, title: card.title, summary: card.summary,
      detailedSummary: card.detailedSummary, distractions: card.distractions, appSites: card.appSites,
      evidenceKind: card.evidenceKind, exactStartTs: pending.startTs, exactEndTs: pending.endTs)
    let result = try StorageManager.shared.replaceTimelineCardGroups([
      TimelineCardReplacementGroup(from: Date(timeIntervalSince1970: Double(pending.startTs)),
        to: Date(timeIntervalSince1970: Double(pending.endTs)), cards: [shell])],
      batchId: pending.batchId, keepingNewerBatchesCardsStartingAfter: Date(timeIntervalSince1970: Double(pending.startTs)),
      pendingToDelete: [id], enforceMinimum: true,
      requiredScreenshotIds: sourceIds + pending.sourceScreenshotIds, requiredPendingIds: [id],
      expectedTimeline: expectedTimeline)
    return result.insertedIds
  }

  private static let timelineFailureToastLastShownDayByKindDefaultsKey =
    "timelineFailureToastLastShownDayByKind"
  private static let timelineFailureToastThrottleQueue = DispatchQueue(
    label: "com.dayflow.timelineFailureToastThrottle"
  )

  private struct TimelineProviderContext {
    let id: LLMProviderID
    let providerLabel: String
    let generateTimeline:
      ([Screenshot], ActivityGenerationContext, Int64?) async throws -> (
        cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?,
        log: LLMCall
      )
    let fallbackState: TimelineFallbackState
  }

  private final class TimelineFallbackState {
    var usedFallback = false
  }

  private func makeConfiguredTimelineContext(_ configuration: AIConfiguration) throws
    -> TimelineProviderContext
  {
    guard let primary = configuration.assignments(for: .timeline).first else {
      throw AIConfiguredRuntimeError.missingRoute
    }
    guard let connection = configuration.connections.first(where: {
      $0.id == primary.connectionID
    }) else { throw AIConfigurationError.missingConnection }
    let runtime = AIConfiguredRuntime(configuration: configuration)
    let fallbackState = TimelineFallbackState()
    return TimelineProviderContext(
      id: connection.kind.providerID,
      providerLabel: connection.name,
      generateTimeline: { [timelineGeneratorOverride] screenshots, context, batchID in
        if let timelineGeneratorOverride {
          return try await timelineGeneratorOverride(screenshots, context, batchID)
        }
        return try await runtime.withConfiguration(feature: .timeline) { provider in
          let result = try await provider.generateTimeline(
            screenshots: screenshots, context: context, batchId: batchID)
          if let selected = AIRequestContext.assignment {
            fallbackState.usedFallback = selected.connection.id != primary.connectionID
              || selected.modelID != primary.modelID || selected.effort != primary.effort
          }
          return result
        }
      },
      fallbackState: fallbackState
    )
  }

  private func operationName(for step: LLMProcessingStep?) -> String {
    switch step {
    case .transcribing:
      return "transcribe"
    case .generatingCards:
      return "generate_cards"
    case .none:
      return "unknown"
    }
  }

  private func isRateLimitError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == "GeminiError" || nsError.domain == "GeminiProvider" {
      if nsError.code == 429 || nsError.code == 403 {
        return true
      }
      let message = nsError.localizedDescription.lowercased()
      if message.contains("quota") || message.contains("rate limit")
        || message.contains("too many requests")
      {
        return true
      }
    }

    let message = error.localizedDescription.lowercased()
    if message.contains("rate limit") || message.contains("too many requests")
      || message.contains("quota exceeded") || message.contains("quota")
      || message.contains("you've hit your limit")
    {
      return true
    }

    return false
  }

  private func emitTimelineFailureToast(
    classification: TimelineFailureClassification,
    operation: LLMProcessingStep?,
    error: Error,
    primaryProvider: String,
    primaryProviderLabel: String,
    backupProvider: String?,
    backupProviderLabel: String?,
    backupConfigured: Bool,
    batchId: Int64?
  ) {
    // Only interrupt the user for problems they have to fix themselves.
    // Everything else is retried automatically after the next success.
    guard let content = classification.toastContent(fallbackProviderLabel: primaryProviderLabel)
    else { return }

    guard shouldEmitTimelineFailureToast(kind: classification.kind) else { return }

    let nsError = error as NSError
    let payload = TimelineFailureToastPayload(
      message: content.body,
      title: content.title,
      providerName: content.providerName,
      steps: content.steps,
      command: content.command,
      waitingSeconds: failedRecordingSecondsInLastDay(),
      destination: content.destination,
      failureKind: classification.kind.rawValue,
      operation: operationName(for: operation),
      primaryProvider: primaryProvider,
      primaryProviderLabel: primaryProviderLabel,
      backupProvider: backupProvider,
      backupProviderLabel: backupProviderLabel,
      backupConfigured: backupConfigured,
      rateLimitDetected: isRateLimitError(error),
      errorDomain: nsError.domain,
      errorCode: nsError.code,
      batchId: batchId
    )
    TimelineFailureToastCenter.post(payload)
  }

  /// Recorded time from the last 24 hours that failed and is waiting to be retried.
  private func failedRecordingSecondsInLastDay(now: Date = Date()) -> Int {
    let cutoff = Int(now.timeIntervalSince1970) - 24 * 60 * 60
    return StorageManager.shared.allBatches()
      .filter { $0.status == "failed" && $0.start >= cutoff }
      .reduce(0) { total, batch in total + max(0, batch.end - batch.start) }
  }

  private func shouldEmitTimelineFailureToast(
    kind: TimelineFailureKind, now: Date = Date()
  ) -> Bool {
    let logicalDay = now.getDayInfoFor4AMBoundary().dayString
    return Self.timelineFailureToastThrottleQueue.sync {
      let defaults = AppStoragePaths.defaults
      var lastShownDayByKind =
        defaults.dictionary(forKey: Self.timelineFailureToastLastShownDayByKindDefaultsKey)
        as? [String: String] ?? [:]
      guard lastShownDayByKind[kind.rawValue] != logicalDay else {
        return false
      }
      lastShownDayByKind[kind.rawValue] = logicalDay
      defaults.set(
        lastShownDayByKind, forKey: Self.timelineFailureToastLastShownDayByKindDefaultsKey)
      return true
    }
  }

  var batchingConfig: BatchingConfig {
    .standard
  }

  /// The stretch of timeline a batch's new cards replace. Providers that were shown only the
  /// cards connected to this batch report the span they rewrote; the rest rewrote the whole
  /// lookback window, so every card in it is replaced.
  static func cardReplacementRange(
    rewriteSpan: Range<Int>?,
    windowStartTime: Date,
    batchEndTime: Date
  ) -> (from: Date, to: Date) {
    guard let rewriteSpan else { return (windowStartTime, batchEndTime) }
    return (
      Date(timeIntervalSince1970: TimeInterval(rewriteSpan.lowerBound)),
      Date(timeIntervalSince1970: TimeInterval(rewriteSpan.upperBound))
    )
  }

  func processBatch(
    _ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)? = nil,
    completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void
  ) {
    Self.batchClaimLock.lock()
    let claimed = Self.claimedBatches.insert(batchId).inserted
    Self.batchClaimLock.unlock()
    guard claimed else {
      completion(.failure(NSError(domain: "LLMService", code: 409,
        userInfo: [NSLocalizedDescriptionKey: "This recording is already being analyzed."])))
      return
    }
    processClaimedBatch(batchId, progressHandler: progressHandler) { result in
      Self.batchClaimLock.lock()
      Self.claimedBatches.remove(batchId)
      Self.batchClaimLock.unlock()
      completion(result)
    }
  }

  private func processClaimedBatch(
    _ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)?,
    completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void
  ) {
    Task {
      var holdsTimelineCardGenerationGate = false
      var replacingTimelineCards = false
      defer {
        if holdsTimelineCardGenerationGate {
          Self.timelineCommitGate.release()
        }
      }

      // Get batch info first (outside do-catch so it's available in catch block)
      let batches = StorageManager.shared.allBatches()
      guard let batchInfo = batches.first(where: { $0.0 == batchId }) else {
        completion(
          .failure(
            NSError(
              domain: "LLMService", code: 2,
              userInfo: [NSLocalizedDescriptionKey: "Batch not found"])))
        return
      }

      let (_, batchStartTs, batchEndTs, _) = batchInfo
      let configuredContext: TimelineProviderContext?
      let configurationError: Error?
      do {
        configuredContext = try makeConfiguredTimelineContext(loadConfiguration())
        configurationError = nil
      } catch {
        // Report setup errors through the ordinary batch failure path.
        configuredContext = nil
        configurationError = error
      }
      let primaryProviderID = configuredContext?.id.analyticsName ?? "unconfigured"
      let primaryProviderLabel = configuredContext?.providerLabel ?? "AI"
      var lastProcessingStep: LLMProcessingStep?
      var hasExistingBatchHistory = false
      var originalSourceSnapshot: [Int64] = []
      var originalPendingSnapshot: [Int64] = []
      var originalCardSnapshot: [Int64] = []
      var expectedTimeline: TimelineRewriteSnapshot?
      print(
        "🧭 [LLMService] processBatch selected primary=\(primaryProviderID) "
          + "label=\(primaryProviderLabel)"
      )

      do {
        print("\n📦 [LLMService] Processing batch \(batchId)")
        print(
          "   Batch time: \(Date(timeIntervalSince1970: TimeInterval(batchStartTs))) to \(Date(timeIntervalSince1970: TimeInterval(batchEndTs)))"
        )

        // Mark batch as processing
        StorageManager.shared.updateBatch(batchId, status: "processing")

        // Get batch start time for timestamp conversion
        let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))

        let screenshots = StorageManager.shared.screenshotsForBatch(batchId)

        guard !screenshots.isEmpty else {
          throw NSError(
            domain: "LLMService", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "No screenshots in batch"])
        }

        // Card-generation lookback window.
        let currentTime = Date(timeIntervalSince1970: TimeInterval(batchEndTs))
        let windowStartTime = currentTime.addingTimeInterval(-batchingConfig.cardLookbackDuration)
        let batchStartTime = batchStartDate

        var pendingCandidate: PendingTimelineEvidence?
        func makeGenerationContext(batchObservations: [Observation]) -> ActivityGenerationContext {
          // Fetch existing timeline cards that overlap with the recent batching window.
          let existingTimelineCards = StorageManager.shared.fetchTimelineCardsByTimeRange(
            from: windowStartTime,
            to: currentTime
          )
          let categoryPolicy = TimelineCategoryWritePolicy.current()
          let protectedEnd = categoryPolicy.protectedHistoryEnd(existingTimelineCards)
          let hasPreviousCardWithinFiveMinutes = StorageManager.shared.hasTimelineCardConnected(
            toBatchStartingAt: batchStartTime,
            maxGap: 5 * 60
          )

          // Establish the full connected history before asking the model to rewrite it.
          // Checking only the frame immediately before this batch can admit older cards
          // across a stop or interleaved recording streams.
          let firstFrame = screenshots.min { $0.capturedAt < $1.capturedAt }
          var continuousFrames: [Screenshot] = []
          var continuousStart = batchStartTs
          if let first = firstFrame {
            let earliestCard = existingTimelineCards.compactMap(\.startTs).min() ?? first.capturedAt
            let history = StorageManager.shared.fetchScreenshotsInTimeRange(
              startTs: min(earliestCard - 120, first.capturedAt - 720), endTs: first.capturedAt - 1)
            continuousFrames = TimelineEvidencePolicy.continuousCaptureSuffix(history + [first],
              recordedContinuity: { TimelineCaptureBoundaries.shared.continuity(from: $0, to: $1) })
            continuousStart = continuousFrames.first?.capturedAt ?? first.capturedAt
            if continuousFrames.first?.id == history.first?.id {
              // Legacy cards can start at the first frame's minute. This tolerance
              // applies only at the start of known evidence, never after a barrier.
              continuousStart = continuousStart / 60 * 60
            }
          }
          let continuous = continuousFrames.count > 1

          // Convert only cards entirely inside that capture span to model context.
          let existingActivityCards = existingTimelineCards.filter { card in
            // End clocks must be exact; a supported earlier start is restored on save.
            guard card.category != "System",
              let start = card.startTs, let end = card.endTs,
              start >= continuousStart,
              !categoryPolicy.isDisabled(card.category),
              protectedEnd.map({ start >= $0 }) ?? true else { return false }
            if let pending = pendingCandidate,
              let range = try? ClaudeOutputValidator.resolveActivityCardInterval(pending.card, nearest: pending.startTs),
              range.lowerBound <= start && end <= range.upperBound { return false }
            return start < end
          }.map { card in
            ActivityCardData(
              startTime: card.startTimestamp,
              endTime: card.endTimestamp,
              category: card.category,
              subcategory: card.subcategory,
              title: card.title,
              summary: card.summary,
              detailedSummary: card.detailedSummary,
              distractions: card.distractions,
              appSites: card.appSites,
              evidenceKind: card.evidenceKind
            )
          }

          let pendingCards = pendingCandidate.flatMap { pending -> [ActivityCardData]? in
            guard !categoryPolicy.isDisabled(pending.card.category),
              protectedEnd.map({ pending.startTs >= $0 }) ?? true else { return nil }
            return [pending.card]
          } ?? []
          return ActivityGenerationContext(
            batchObservations: batchObservations,
            existingCards: existingActivityCards + pendingCards,
            currentTime: currentTime,
            categories: categoryPolicy.descriptors,
            hasPreviousCardWithinFiveMinutes: hasPreviousCardWithinFiveMinutes || pendingCandidate != nil,
            hasContinuousCaptureBeforeBatch: continuous
          )
        }

        lastProcessingStep = .generatingCards
        await MainActor.run {
          progressHandler?(.generatingCards)
        }

        // Snapshot planning and commits are short critical sections. Provider
        // requests run outside this gate and may overlap unrelated retries.
        await Self.timelineCommitGate.acquire()
        holdsTimelineCardGenerationGate = true
        expectedTimeline = try StorageManager.shared.captureTimelineRewriteSnapshot(
          from: min(Int(windowStartTime.timeIntervalSince1970) - 3600 - 60, batchStartTs - 3600),
          to: batchEndTs / 60 * 60 + 60)
        let priorPending = StorageManager.shared.pendingTimelineEvidence()

        if let first = screenshots.min(by: { $0.capturedAt < $1.capturedAt }) {
          let history = StorageManager.shared.fetchScreenshotsInTimeRange(
            startTs: first.capturedAt - 720, endTs: first.capturedAt - 1)
          if let previousFrame = history.last,
            TimelineEvidencePolicy.captureContinues(history: history, next: first,
              recordedContinuity: TimelineCaptureBoundaries.shared.continuity(from: previousFrame.capturedAt, to: first.capturedAt)) {
            let pending = StorageManager.shared.pendingTimelineEvidence().last { item in
              !TimelineCategoryWritePolicy.current().isDisabled(item.card.category)
                && item.endTs == previousFrame.capturedAt && item.lastScreenshotId == previousFrame.id
                && Date(timeIntervalSince1970: Double(item.startTs)).getDayInfoFor4AMBoundary().dayString
                  == first.capturedDate.getDayInfoFor4AMBoundary().dayString
                && first.capturedAt - item.startTs <= 3600
                && (item.card.evidenceKind == nil || item.card.evidenceKind == .visible || item.card.evidenceKind == .privacyRedacted)
            }
            pendingCandidate = pending
          }
        }
        let generationContext = makeGenerationContext(batchObservations: [])
        let exactHistory = StorageManager.shared.fetchTimelineCardsByTimeRange(from: windowStartTime, to: currentTime)
        func historicalClockRange(_ previous: TimelineCard) -> Range<Int>? {
          guard let card = generationContext.existingCards.first(where: {
            $0.startTime == previous.startTimestamp && $0.endTime == previous.endTimestamp
          }) else { return nil }
          return try? ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: batchStartTs)
        }
        hasExistingBatchHistory = exactHistory.contains { card in
          card.category != "System" && (card.startTs ?? Int.max) < batchEndTs
            && (card.endTs ?? Int.min) > batchStartTs
        }
        // Snapshot the original inputs before awaiting the provider. A later
        // read alone cannot reveal that an intermediate frame was removed.
        var originalSourceIds = Set(screenshots.map(\.id))
        if let pendingCandidate { originalSourceIds.formUnion(pendingCandidate.sourceScreenshotIds) }
        let sourceStart = min(Int(windowStartTime.timeIntervalSince1970), pendingCandidate?.startTs ?? batchStartTs)
        let earlierSources = StorageManager.shared.fetchScreenshotsInTimeRange(
          startTs: sourceStart, endTs: batchStartTs - 1)
        let contextRanges = generationContext.existingCards.compactMap {
          try? ClaudeOutputValidator.resolveActivityCardInterval($0, nearest: batchStartTs)
        }
        for frame in earlierSources where contextRanges.contains(where: { $0.contains(frame.capturedAt) })
          || (pendingCandidate.map { frame.capturedAt >= $0.startTs && frame.capturedAt <= $0.endTs } ?? false) {
          originalSourceIds.insert(frame.id)
        }
        originalSourceSnapshot = Array(originalSourceIds)
        originalPendingSnapshot = [pendingCandidate?.id].compactMap { $0 }
        originalCardSnapshot = exactHistory.compactMap { card in
          guard generationContext.existingCards.contains(where: {
            $0.startTime == card.startTimestamp && $0.endTime == card.endTimestamp
          }) else { return nil }
          return card.recordId
        }
        let generator: TimelineEvidencePolicy.Generate = configuredContext?.generateTimeline ?? { _, _, _ in
          throw configurationError ?? AIConfiguredRuntimeError.missingRoute
        }
        Self.timelineCommitGate.release()
        holdsTimelineCardGenerationGate = false
        let result = try await TimelineEvidencePolicy.generate(
          screenshots: screenshots, context: generationContext,
          batchId: batchId, using: generator)
        await Self.timelineCommitGate.acquire()
        holdsTimelineCardGenerationGate = true
        let generatedCards = result.cards
        let isBackupGenerated = configuredContext?.fallbackState.usedFallback ?? false
        print(
          "🧩 [LLMService] One-step timeline → \(generatedCards.count) cards, "
            + "\(result.observations.count) observations")

        // Model clocks are minute-rounded. Publish only the range bounded by actual
        // captured evidence; keep shorter output as pending facts, outside the timeline.
        let earliest = min(Int(windowStartTime.timeIntervalSince1970), pendingCandidate?.startTs ?? screenshots.first!.capturedAt)
        // A batch can begin near the end of an MP4. Retain the preceding segment
        // context for rotation checks, without publishing or attaching its older
        // activity to the generated card. A suffix starting at index 13 is not
        // evidence that the segment itself lacked index 0.
        let evidence = StorageManager.shared.fetchScreenshotsInTimeRange(
          startTs: earliest - Int(FrameStore.segmentDuration) - 120,
          endTs: screenshots.last!.capturedAt)
        var publishedCards: [ActivityCardData] = []
        var insertedCardIds: [Int64] = []
        var deletedVideoPaths: [String] = []
        var committed = false
        var didCallCommitHook = false
        for attempt in 0..<3 {
          // Re-read switches after the async provider and the final commit hook.
          // Historical labels are protected, not normalized into the new fallback.
          if !didCallCommitHook { beforeTimelineCommit?(); didCallCommitHook = true }
          let commitHistory = StorageManager.shared.fetchTimelineCardsByTimeRange(
            from: windowStartTime, to: currentTime)
          let categoryPolicy = TimelineCategoryWritePolicy.current()
          let minimum = Int(AnalysisPreferences.interval)
          let normalizedCards = try categoryPolicy.cardsForCommit(
            generatedCards, history: commitHistory, nearest: batchStartTs)
          let cards = try TimelineStabilizedCommit.cards(normalizedCards, nearest: batchStartTs, minimum: minimum)
          let protectedFloor = categoryPolicy.protectedHistoryEnd(commitHistory).map { ($0 + 59) / 60 * 60 }
          var pendingToSave: [PendingTimelineEvidence] = []
          var pendingToDelete: [Int64] = []
          var replacementGroups: [TimelineCardReplacementGroup] = []
          var currentPublishedCards: [ActivityCardData] = []
          var requiredSourceIds = originalSourceIds
          var replacementSourceIDs: Set<Int64> = []
          var consumedCardIDs: Set<Int64> = []
          for (cardIndex, card) in cards.enumerated() {
            let range = try ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: batchStartTs)
            let nextRange = cardIndex + 1 < cards.count
              ? try ClaudeOutputValidator.resolveActivityCardInterval(cards[cardIndex + 1], nearest: batchStartTs) : nil
            let currentRunIDs = Set(card.sourceScreenshotIDs ?? screenshots.map(\.id))
            let previousRunIDs: Set<Int64>? = cardIndex > 0
              ? Set(cards[cardIndex - 1].sourceScreenshotIDs ?? screenshots.map(\.id)) : nil
            let nextRunIDs: Set<Int64>? = cardIndex + 1 < cards.count
              ? Set(cards[cardIndex + 1].sourceScreenshotIDs ?? screenshots.map(\.id)) : nil
            let isFirstInRun = previousRunIDs != currentRunIDs
            let isLastInRun = nextRunIDs != currentRunIDs
            let boundaryStartsAnotherCard = !isLastInRun && nextRange?.lowerBound == range.upperBound
            if card.category == "System" {
              replacementGroups.append(TimelineCardReplacementGroup(
                from: Date(timeIntervalSince1970: Double(range.lowerBound)),
                to: Date(timeIntervalSince1970: Double(range.upperBound)),
                cards: [TimelineCardShell(startTimestamp: card.startTime, endTimestamp: card.endTime,
                  category: card.category, subcategory: card.subcategory, title: card.title,
                  summary: card.summary, detailedSummary: card.detailedSummary,
                  distractions: card.distractions, appSites: card.appSites, evidenceKind: card.evidenceKind)]))
              continue
            }
            // Only the first capture run can extend the batch's lookback.
            // Minute-rounded clocks from later runs may overlap that history.
            let runSourceIDs = Set(card.sourceScreenshotIDs ?? screenshots.map(\.id))
            let mayExtendHistory = runSourceIDs.contains(screenshots.first!.id)
            let matchingHistory = exactHistory.filter { previous in
              guard mayExtendHistory, generationContext.hasContinuousCaptureBeforeBatch,
                let clockRange = historicalClockRange(previous),
                clockRange.lowerBound >= range.lowerBound, clockRange.upperBound <= range.upperBound,
                !categoryPolicy.isDisabled(previous.category),
                previous.evidenceKind == nil || previous.evidenceKind == .visible || previous.evidenceKind == .privacyRedacted
              else { return false }
              return generationContext.existingCards.contains {
                $0.startTime == previous.startTimestamp && $0.endTime == previous.endTimestamp
              }
            }
            let matchedPending = pendingCandidate.flatMap { pending -> PendingTimelineEvidence? in
              guard mayExtendHistory,
                range.lowerBound <= pending.startTs && range.upperBound >= pending.endTs
              else { return nil }
              return pending
            }
            var allowedSourceIDs = runSourceIDs
            if let matchedPending { allowedSourceIDs.formUnion(matchedPending.sourceScreenshotIds) }
            for frame in earlierSources where matchingHistory.contains(where: {
              frame.capturedAt >= ($0.startTs ?? Int.max) && frame.capturedAt <= ($0.endTs ?? Int.min)
            }) || (matchedPending.map { frame.capturedAt >= $0.startTs && frame.capturedAt <= $0.endTs } ?? false) {
              allowedSourceIDs.insert(frame.id)
            }
            let runFrames = screenshots.filter { runSourceIDs.contains($0.id) }
            guard let runFirst = runFrames.first, let runLast = runFrames.last else {
              throw ClaudeOutputValidationError.missingEvidenceCoverage
            }
            let runStart = runFirst.capturedAt
            let sourceStart = min(runStart, matchedPending?.startTs ?? runStart,
              matchingHistory.compactMap(\.startTs).min() ?? runStart)
            let lower = max(protectedFloor ?? Int.min,
              isFirstInRun ? min(range.lowerBound, sourceStart) : max(range.lowerBound, sourceStart))
            let restoredHistoryEnd = matchingHistory.filter {
              historicalClockRange($0)?.upperBound == range.upperBound
            }.compactMap(\.endTs).max() ?? range.upperBound
            let upper = isLastInRun ? max(range.upperBound, runLast.capturedAt + 1)
              : max(range.upperBound, restoredHistoryEnd)
            let supported = evidence.filter {
              allowedSourceIDs.contains($0.id) && $0.capturedAt >= lower
                && ($0.capturedAt < upper || (!boundaryStartsAnotherCard && $0.capturedAt == upper))
            }
            // Every card in the run uses the same publication eligibility window.
            // Distinct short switches are stabilized by the generator, never hidden.
            let relatedCards = cards.filter {
              Set($0.sourceScreenshotIDs ?? screenshots.map(\.id)) == runSourceIDs
            }
            let relatedRanges = try relatedCards.map {
              try ClaudeOutputValidator.resolveActivityCardInterval($0, nearest: batchStartTs)
            }
            let fullLower = relatedRanges.map(\.lowerBound).min() ?? range.lowerBound
            let fullUpper = relatedRanges.map(\.upperBound).max() ?? range.upperBound
            let runHistory = mayExtendHistory ? exactHistory.filter { previous in
              guard generationContext.hasContinuousCaptureBeforeBatch,
                let clockRange = historicalClockRange(previous),
                clockRange.lowerBound >= fullLower, clockRange.upperBound <= fullUpper,
                !categoryPolicy.isDisabled(previous.category) else { return false }
              return true
            } : []
            consumedCardIDs.formUnion((matchingHistory + runHistory).compactMap(\.recordId))
            let historicalStart = runHistory.compactMap(\.startTs).min()
            let pendingStart = mayExtendHistory ? pendingCandidate.flatMap {
              fullLower <= $0.startTs && fullUpper >= $0.endTs ? $0.startTs : nil
            } : nil
            let stabilityStart = max(protectedFloor ?? Int.min,
              min(runStart, historicalStart ?? runStart, pendingStart ?? runStart))
            let stabilityWindow = stabilityStart..<runLast.capturedAt
            guard let first = supported.first, let last = supported.last else {
              throw ClaudeOutputValidationError.missingEvidenceCoverage
            }
            let supportingPaths = Set(supported.map(\.filePath))
            let continuityHistory = evidence.filter {
              $0.capturedAt < first.capturedAt && supportingPaths.contains($0.filePath)
            }
            var checkedHistory = continuityHistory
            for frame in supported {
              if let previous = checkedHistory.last, previous.capturedAt >= first.capturedAt {
                let stop = TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: frame.capturedAt)
                let sameDay = previous.capturedDate.getDayInfoFor4AMBoundary().dayString
                  == frame.capturedDate.getDayInfoFor4AMBoundary().dayString
                let sameCapture = TimelineEvidencePolicy.captureContinues(
                  history: checkedHistory, next: frame, recordedContinuity: stop)
                guard sameDay && sameCapture else { throw ClaudeOutputValidationError.cardCoversEvidenceGap(title: card.title) }
              }
              checkedHistory.append(frame)
            }
            requiredSourceIds.formUnion(checkedHistory.map(\.id))
            replacementSourceIDs.formUnion(supported.map(\.id))
            let firstId = first.id, lastId = last.id
            let start = min(first.capturedAt, matchingHistory.compactMap(\.startTs).min() ?? first.capturedAt)
            // The last capture before a change still belongs to the preceding
            // event until the next event's first capture. Use one shared seam,
            // instead of leaving one capture interval blank between cards.
            let seamFrames = evidence.filter { frame in
              runSourceIDs.contains(frame.id) || runHistory.contains {
                frame.capturedAt >= ($0.startTs ?? Int.max) && frame.capturedAt <= ($0.endTs ?? Int.min)
              } || (pendingStart.map { frame.capturedAt >= $0 && frame.capturedAt < runStart } ?? false)
            }
            let seam = !isLastInRun ? nextRange.flatMap { next in
              seamFrames.first { $0.capturedAt >= next.lowerBound }?.capturedAt
            } : nil
            let end = seam ?? last.capturedAt
            if let seam, let seamFrame = seamFrames.first(where: { $0.capturedAt == seam }) {
              requiredSourceIds.insert(seamFrame.id)
            }
            for old in priorPending where old.batchId == batchId && old.id != nil
              && start <= old.startTs && end >= old.endTs
              && allowedSourceIDs.contains(old.firstScreenshotId)
              && allowedSourceIDs.contains(old.lastScreenshotId) {
              pendingToDelete.append(old.id!)
            }
            if let pending = matchedPending, let id = pending.id {
              if !pendingToDelete.contains(id) { pendingToDelete.append(id) }
            }
            if stabilityWindow.upperBound - stabilityWindow.lowerBound < minimum {
              // Retain this provider input span, not unrelated capture spans
              // that happened to share the surrounding batch.
              let pendingSourceIds = allowedSourceIDs
              pendingToSave.append(PendingTimelineEvidence(id: nil, batchId: batchId,
                startTs: start, endTs: end, card: card,
                firstScreenshotId: firstId, lastScreenshotId: lastId,
                sourceScreenshotIds: Array(pendingSourceIds)))
              continue
            }
            currentPublishedCards.append(card)
            replacementGroups.append(TimelineCardReplacementGroup(
              from: Date(timeIntervalSince1970: Double(start)),
              to: Date(timeIntervalSince1970: Double(end)),
              cards: [TimelineCardShell(startTimestamp: TimelineOutputPolicy().formatTimestampForPrompt(start),
                endTimestamp: TimelineOutputPolicy().formatTimestampForPrompt(isLastInRun ? end / 60 * 60 + 60 : end),
                category: card.category, subcategory: card.subcategory, title: card.title,
                summary: card.summary, detailedSummary: card.detailedSummary,
                distractions: card.distractions, appSites: card.appSites,
                isBackupGenerated: isBackupGenerated ? true : nil, evidenceKind: card.evidenceKind,
                exactStartTs: start, exactEndTs: end)], stabilityWindow: stabilityWindow))
          }
          // A retry can split one old pending event into several new cards.
          // Replace its facts using the union of all new exact source frames,
          // while retaining pending records from runs absent from this rewrite.
          for old in priorPending where old.batchId == batchId && old.id != nil
            && !pendingToDelete.contains(old.id!)
            && replacementSourceIDs.contains(old.firstScreenshotId)
            && replacementSourceIDs.contains(old.lastScreenshotId) {
            let oldIDs = Set(old.sourceScreenshotIds)
            let oldIntervalSources = evidence.filter {
              $0.capturedAt >= old.startTs && $0.capturedAt <= old.endTs
                && (oldIDs.isEmpty || oldIDs.contains($0.id))
            }.map(\.id)
            if !oldIntervalSources.isEmpty && Set(oldIntervalSources).isSubset(of: replacementSourceIDs) {
              pendingToDelete.append(old.id!)
            }
          }
          do {
            replacingTimelineCards = true
            let saved = try StorageManager.shared.replaceTimelineCardGroups(
              replacementGroups, batchId: batchId,
              keepingNewerBatchesCardsStartingAfter: batchStartTime,
              pendingToSave: pendingToSave, pendingToDelete: pendingToDelete, enforceMinimum: true,
              markBatchAnalyzed: true, replacementObservations: result.observations,
              requiredScreenshotIds: Array(requiredSourceIds),
              requiredPendingIds: [pendingCandidate?.id].compactMap { $0 },
              requiredCardIds: Array(consumedCardIDs), expectedTimeline: expectedTimeline)
            insertedCardIds = saved.insertedIds
            deletedVideoPaths = saved.deletedVideoPaths
            publishedCards = currentPublishedCards
            committed = true
            break
          } catch TimelineCardReplacementError.minimumDurationChanged where attempt < 2 {
            // Reclassify the same generated evidence with the latest setting, without
            // calling the provider again or touching the previous timeline.
            replacingTimelineCards = false
            continue
          }
        }
        guard committed else { throw TimelineCardReplacementError.minimumDurationChanged }
        replacingTimelineCards = false

        for path in deletedVideoPaths {
          let url = URL(fileURLWithPath: path)
          guard AppStoragePaths.canRemoveGeneratedMedia(at: url) else { continue }
          do {
            try FileManager.default.removeItem(at: url)
            print("🗑️ Deleted timelapse: \(path)")
          } catch {
            print("❌ Failed to delete timelapse: \(path) - \(error)")
          }
        }

        // Mark batch as complete
        StorageManager.shared.updateBatch(batchId, status: "analyzed")

        // Checkpoint WAL after batch processing to ensure data is persisted
        StorageManager.shared.checkpoint(mode: .passive)

        // Track analysis batch completed

        TimelineFailureToastCenter.hide()

        completion(.success(ProcessedBatchResult(cards: publishedCards, cardIds: insertedCardIds,
          providerWasUsed: true)))

      } catch {
        if !holdsTimelineCardGenerationGate {
          await Self.timelineCommitGate.acquire()
          holdsTimelineCardGenerationGate = true
        }

        // A stale result is not a provider failure and must never replace newer
        // cards with either its generated output or a failure placeholder.
        let timelineChanged = (error as? TimelineCardReplacementError) == .timelineChanged
        if timelineChanged {
          completion(.failure(TimelineCardReplacementError.timelineChanged))
          return
        }
        print("Error processing batch: \(error)")
        if let ns = error as NSError?, ns.domain == "GeminiError" {
          print("🔎 GEMINI DEBUG: NSError.userInfo=\(ns.userInfo)")
        }

        let sourceChanged = error is TimelineCardReplacementError
          && (error as? TimelineCardReplacementError) == .sourceEvidenceChanged
          || (!originalSourceSnapshot.isEmpty && !StorageManager.shared.timelineSourcesAreActive(
            screenshotIds: originalSourceSnapshot, pendingIds: originalPendingSnapshot,
            cardIds: originalCardSnapshot))
        if sourceChanged {
          StorageManager.shared.updateBatch(batchId, status: "failed", reason: "Source evidence changed during analysis")
          completion(.failure(TimelineCardReplacementError.sourceEvidenceChanged))
          return
        }
        let failureClassification = TimelineFailureClassifier.classify(error)

        // Track analysis batch failed

        // A failed replacement has rolled back; no second write may change its history.
        if replacingTimelineCards {
          StorageManager.shared.updateBatch(batchId, status: "failed", reason: error.localizedDescription)
          emitTimelineFailureToast(
            classification: failureClassification,
            operation: lastProcessingStep,
            error: error,
            primaryProvider: primaryProviderID,
            primaryProviderLabel: primaryProviderLabel,
            backupProvider: nil,
            backupProviderLabel: nil,
            backupConfigured: false,
            batchId: batchId
          )

          completion(.failure(error))
          return
        }

        let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))
        let failedScreenshots = StorageManager.shared.screenshotsForBatch(batchId)
        let failedSpans = TimelineEvidencePolicy.partition(failedScreenshots)
        let protectHistory = hasExistingBatchHistory || error is TimelineNaturalMergeError
        let failureGroups: [TimelineCardReplacementGroup] = protectHistory ? [] : failedSpans.compactMap { span in
          let start = Date(timeIntervalSince1970: Double(span.startTs))
          let end = Date(timeIntervalSince1970: Double(span.endTs))
          return TimelineCardReplacementGroup(from: start, to: end, cards: [
            createErrorCard(batchStartTime: start, batchEndTime: end,
              message: failureClassification.cardMessage(fallbackProviderLabel: primaryProviderLabel))])
        }

        let savedFailure: (insertedIds: [Int64], deletedVideoPaths: [String])?
        do {
          savedFailure = try StorageManager.shared.replaceTimelineCardGroups(
            failureGroups, batchId: batchId, keepingNewerBatchesCardsStartingAfter: batchStartDate,
            requiredScreenshotIds: originalSourceSnapshot,
            requiredPendingIds: originalPendingSnapshot,
            requiredCardIds: originalCardSnapshot, expectedTimeline: expectedTimeline)
        } catch TimelineCardReplacementError.timelineChanged {
          completion(.failure(TimelineCardReplacementError.timelineChanged))
          return
        } catch {
          completion(.failure(error))
          return
        }
        StorageManager.shared.updateBatch(batchId, status: "failed", reason: error.localizedDescription)
        if savedFailure != nil {
          emitTimelineFailureToast(
            classification: failureClassification,
            operation: lastProcessingStep,
            error: error,
            primaryProvider: primaryProviderID,
            primaryProviderLabel: primaryProviderLabel,
            backupProvider: nil,
            backupProviderLabel: nil,
            backupConfigured: false,
            batchId: batchId
          )

        }
        let insertedCardIds = savedFailure?.insertedIds ?? []
        let deletedVideoPaths = savedFailure?.deletedVideoPaths ?? []

        // Clean up any deleted video files (if there were existing cards)
        for path in deletedVideoPaths {
          let url = URL(fileURLWithPath: path)
          guard AppStoragePaths.canRemoveGeneratedMedia(at: url) else { continue }
          do {
            try FileManager.default.removeItem(at: url)
            print("🗑️ Deleted timelapse for replaced card: \(path)")
          } catch {
            print("❌ Failed to delete timelapse: \(path) - \(error)")
          }
        }

        if !insertedCardIds.isEmpty {
          print(
            "✅ Created error card (ID: \(insertedCardIds.first ?? -1)) for failed batch \(batchId), replacing \(deletedVideoPaths.count) existing cards"
          )
        }

        // Still return failure but with the error card created
        completion(.failure(error))
      }
    }
  }

  private func createErrorCard(
    batchStartTime: Date, batchEndTime: Date, message: String
  ) -> TimelineCardShell {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    let startTimeStr = formatter.string(from: batchStartTime)
    let endTimeStr = formatter.string(from: batchEndTime)

    // The title stays the English sentinel the timeline uses to spot failed cards.
    // No detailed summary: raw error text never reaches the card.
    return TimelineCardShell(
      startTimestamp: startTimeStr,
      endTimestamp: endTimeStr,
      category: "System",
      subcategory: "Error",
      title: "Processing failed",
      summary: message + " " + String(localized: "Your recording is saved."),
      detailedSummary: "",
      distractions: nil,
      appSites: nil
    )
  }

  // MARK: - Text Generation

  private func generateConfiguredText(prompt: String, feature: AIFeature) async throws -> String {
    let configuration = try loadConfiguration()
    guard !configuration.assignments(for: feature).isEmpty else {
      throw AIConfiguredRuntimeError.missingRoute
    }
    if let configuredText { return try await configuredText(prompt, feature) }
    return try await AIConfiguredRuntime(configuration: configuration)
      .generateText(prompt: prompt, feature: feature).text
  }

  func generateTargetEvaluation(prompt: String) async throws -> String {
    try await generateConfiguredText(prompt: prompt, feature: .targetEvaluation)
  }

}
