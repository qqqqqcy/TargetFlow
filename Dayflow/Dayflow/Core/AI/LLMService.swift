//
//  LLMService.swift
//  Dayflow
//

import AppKit
import Combine
import Foundation
import GRDB
import SwiftUI

private final class TimelineCardGenerationGate: @unchecked Sendable {
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

  private static let timelineCardGenerationGate = TimelineCardGenerationGate()

  /// Publish already generated facts after a settings decrease; serialization and the
  /// conditional pending deletion make this safe against a concurrent batch rewrite.
  static func publishEligiblePending(_ pending: PendingTimelineEvidence, beforeCommit: (() -> Void)? = nil) async throws -> [Int64] {
    await timelineCardGenerationGate.acquire()
    defer { timelineCardGenerationGate.release() }
    guard let id = pending.id, pending.endTs - pending.startTs >= Int(AnalysisPreferences.interval),
      pending.endTs - pending.startTs <= 3600,
      StorageManager.shared.pendingTimelineEvidence().contains(where: { $0.id == id })
    else { return [] }
    let sourceIds = StorageManager.shared.fetchScreenshotsInTimeRange(
      startTs: pending.startTs, endTs: pending.endTs).map(\.id)
    let card = pending.card
    let policy = TimelineOutputPolicy()
    let shell = TimelineCardShell(startTimestamp: policy.formatTimestampForPrompt(pending.startTs),
      endTimestamp: policy.formatTimestampForPrompt(pending.endTs / 60 * 60 + 60),
      category: card.category, subcategory: card.subcategory, title: card.title, summary: card.summary,
      detailedSummary: card.detailedSummary, distractions: card.distractions, appSites: card.appSites,
      evidenceKind: card.evidenceKind, exactStartTs: pending.startTs, exactEndTs: pending.endTs)
    beforeCommit?()
    let result = try StorageManager.shared.replaceTimelineCardGroups([
      TimelineCardReplacementGroup(from: Date(timeIntervalSince1970: Double(pending.startTs)),
        to: Date(timeIntervalSince1970: Double(pending.endTs)), cards: [shell])],
      batchId: pending.batchId, keepingNewerBatchesCardsStartingAfter: Date(timeIntervalSince1970: Double(pending.startTs)),
      pendingToDelete: [id], enforceMinimum: true,
      requiredScreenshotIds: sourceIds + pending.sourceScreenshotIds, requiredPendingIds: [id])
    return result.insertedIds
  }

  private static func localPrivacyPending(batchId: Int64, screenshots: [Screenshot])
    -> (records: [PendingTimelineEvidence], consumed: [Int64], sources: [Int64], cards: [Int64]) {
    var failurePrivacy: [PendingTimelineEvidence] = []
    var consumedPrivacy: [Int64] = []
    var requiredSources = Set(screenshots.map(\.id))
    var requiredCards: [Int64] = []
    let oldPending = StorageManager.shared.pendingTimelineEvidence()
    for span in TimelineEvidencePolicy.partition(screenshots) where span.kind == .privacyRedacted {
      let frames = span.screenshots.filter(\.isPrivacyRedacted).sorted { $0.capturedAt < $1.capturedAt }
      guard let first = frames.first, let last = frames.last else { continue }
      let history = StorageManager.shared.fetchScreenshotsInTimeRange(
        startTs: first.capturedAt - 720, endTs: first.capturedAt - 1)
      let previousFrame = first.id == screenshots.first?.id ? history.last : nil
      let continuous = previousFrame.map { previous in
        TimelineEvidencePolicy.captureContinues(history: history, next: first,
          recordedContinuity: TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: first.capturedAt), privacy: true)
          && previous.capturedDate.getDayInfoFor4AMBoundary().dayString == first.capturedDate.getDayInfoFor4AMBoundary().dayString
      } ?? false
      let pending = continuous ? oldPending.last { item in
        item.card.evidenceKind == .privacyRedacted && item.endTs == previousFrame?.capturedAt
          && item.lastScreenshotId == previousFrame?.id && last.capturedAt - item.startTs <= 3600
      } : nil
      let previousCard = continuous ? StorageManager.shared.fetchTimelineCardEndingLast(
        startingBefore: first.capturedDate, excludingBatchId: batchId).flatMap { card in
          card.evidenceKind == .privacyRedacted && card.endTs == previousFrame?.capturedAt
            && last.capturedAt - card.startTs <= 3600 ? card : nil
        } : nil
      let start = min(first.capturedAt, pending?.startTs ?? first.capturedAt,
        previousCard?.startTs ?? first.capturedAt)
      let protectedFrames = StorageManager.shared.fetchScreenshotsInTimeRange(startTs: start, endTs: last.capturedAt)
        .filter(\.isPrivacyRedacted)
      guard let sourceFirst = protectedFrames.first, let sourceLast = protectedFrames.last else { continue }
      var continuousSpan = true
      for index in protectedFrames.indices.dropFirst() {
        let previous = protectedFrames[protectedFrames.index(before: index)]
        let next = protectedFrames[index]
        if previous.capturedDate.getDayInfoFor4AMBoundary().dayString != next.capturedDate.getDayInfoFor4AMBoundary().dayString
          || !TimelineEvidencePolicy.captureContinues(history: Array(protectedFrames[..<index]), next: next,
            recordedContinuity: TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: next.capturedAt), privacy: true) {
          continuousSpan = false
          break
        }
      }
      guard continuousSpan else { continue }
      let card = TimelineEvidencePolicy.privacyCard(start: TimelineOutputPolicy().formatTimestampForPrompt(start),
        end: TimelineOutputPolicy().formatTimestampForPrompt(last.capturedAt / 60 * 60 + 60))
      var sources = Set(span.screenshots.map(\.id) + protectedFrames.map(\.id))
      if let pending { sources.formUnion(pending.sourceScreenshotIds) }
      if continuous { sources.formUnion(history.suffix(2).map(\.id)) }
      if let previousCard { requiredCards.append(previousCard.id) }
      requiredSources.formUnion(sources)
      for old in oldPending where old.batchId == batchId && old.card.evidenceKind == .privacyRedacted
        && old.startTs >= span.startTs && old.endTs <= span.endTs {
        if let id = old.id, !consumedPrivacy.contains(id) { consumedPrivacy.append(id) }
      }
      if let id = pending?.id, !consumedPrivacy.contains(id) { consumedPrivacy.append(id) }
      failurePrivacy.append(PendingTimelineEvidence(id: nil, batchId: batchId, startTs: start,
        endTs: last.capturedAt, card: card, firstScreenshotId: sourceFirst.id,
        lastScreenshotId: sourceLast.id, sourceScreenshotIds: Array(sources)))
    }
    return (failurePrivacy, consumedPrivacy, Array(requiredSources), requiredCards)
  }

  /// Sealed sub-minute batches never call the provider; retain protected facts locally.
  static func saveShortPrivacyEvidence(batchId: Int64, screenshots: [Screenshot]) async throws {
    await timelineCardGenerationGate.acquire()
    defer { timelineCardGenerationGate.release() }
    let local = localPrivacyPending(batchId: batchId, screenshots: screenshots)
    _ = try StorageManager.shared.replaceTimelineCardGroups([], batchId: batchId,
      keepingNewerBatchesCardsStartingAfter: nil, pendingToSave: local.records,
      pendingToDelete: local.consumed, requiredScreenshotIds: local.sources,
      requiredPendingIds: local.consumed, requiredCardIds: local.cards)
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
    Task {
      var holdsTimelineCardGenerationGate = false
      var replacingTimelineCards = false
      defer {
        if holdsTimelineCardGenerationGate {
          Self.timelineCardGenerationGate.release()
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
        // Privacy-only evidence is local and can still be handled without a
        // configured model. Visible evidence reports the original setup error.
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
        var privacyCandidate: PendingTimelineEvidence?
        var privacyPreviousFrame: Screenshot?
        func makeGenerationContext(batchObservations: [Observation]) -> ActivityGenerationContext {
          // Fetch existing timeline cards that overlap with the recent batching window.
          let existingTimelineCards = StorageManager.shared.fetchTimelineCardsByTimeRange(
            from: windowStartTime,
            to: currentTime
          )
          let hasPreviousCardWithinFiveMinutes = StorageManager.shared.hasTimelineCardConnected(
            toBatchStartingAt: batchStartTime,
            maxGap: 5 * 60
          )

          // Convert TimelineCards to ActivityCardData for context
          let existingActivityCards = existingTimelineCards.filter { card in
            // End clocks must be exact; a supported earlier start is restored on save.
            guard card.category != "System", card.evidenceKind != .privacyRedacted,
              let start = card.startTs, let end = card.endTs else { return false }
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

          let firstFrame = screenshots.min { $0.capturedAt < $1.capturedAt }
          let continuous = firstFrame.map { first in
            let history = StorageManager.shared.fetchScreenshotsInTimeRange(
              startTs: first.capturedAt - 720, endTs: first.capturedAt - 1)
            let boundary = history.last.flatMap {
              TimelineCaptureBoundaries.shared.continuity(from: $0.capturedAt, to: first.capturedAt)
            }
            return TimelineEvidencePolicy.captureContinues(history: history, next: first, recordedContinuity: boundary)
          } ?? false
          let pendingCards = pendingCandidate.map { [$0.card] } ?? []
          return ActivityGenerationContext(
            batchObservations: batchObservations,
            existingCards: existingActivityCards + pendingCards,
            currentTime: currentTime,
            categories: CategoryStore.descriptorsForLLM(),
            hasPreviousCardWithinFiveMinutes: hasPreviousCardWithinFiveMinutes || pendingCandidate != nil,
            hasContinuousCaptureBeforeBatch: continuous
          )
        }

        lastProcessingStep = .generatingCards
        await MainActor.run {
          progressHandler?(.generatingCards)
        }

        // Timeline reads, generation, and replacement form one serialized rewrite.
        await Self.timelineCardGenerationGate.acquire()
        holdsTimelineCardGenerationGate = true

        if let first = screenshots.min(by: { $0.capturedAt < $1.capturedAt }) {
          let history = StorageManager.shared.fetchScreenshotsInTimeRange(
            startTs: first.capturedAt - 720, endTs: first.capturedAt - 1)
          if let previousFrame = history.last,
            TimelineEvidencePolicy.captureContinues(history: history, next: first,
              recordedContinuity: TimelineCaptureBoundaries.shared.continuity(from: previousFrame.capturedAt, to: first.capturedAt),
              privacy: first.isPrivacyRedacted) {
            let pending = StorageManager.shared.pendingTimelineEvidence().last { item in
              item.endTs == previousFrame.capturedAt && item.lastScreenshotId == previousFrame.id
                && Date(timeIntervalSince1970: Double(item.startTs)).getDayInfoFor4AMBoundary().dayString
                  == first.capturedDate.getDayInfoFor4AMBoundary().dayString
                && first.capturedAt - item.startTs <= 3600
                && (first.isPrivacyRedacted ? item.card.evidenceKind == .privacyRedacted
                  : (item.card.evidenceKind == nil || item.card.evidenceKind == .visible))
            }
            if first.isPrivacyRedacted,
              previousFrame.capturedDate.getDayInfoFor4AMBoundary().dayString == first.capturedDate.getDayInfoFor4AMBoundary().dayString {
              privacyCandidate = pending
              privacyPreviousFrame = previousFrame
            } else if !first.isPrivacyRedacted {
              pendingCandidate = pending
            }
          }
        }
        let generationContext = makeGenerationContext(batchObservations: [])
        let exactHistory = StorageManager.shared.fetchTimelineCardsByTimeRange(from: windowStartTime, to: currentTime)
        let previousPrivacy = privacyPreviousFrame.flatMap { frame in
          exactHistory.last { card in
            card.evidenceKind == .privacyRedacted && card.endTs == frame.capturedAt
              && card.startTs.map { frame.capturedAt - $0 < 3600 } == true
          }
        }
        hasExistingBatchHistory = exactHistory.contains { card in
          card.category != "System" && (card.startTs ?? Int.max) < batchEndTs
            && (card.endTs ?? Int.min) > batchStartTs
        }
        // Snapshot the original inputs before awaiting the provider. A later
        // read alone cannot reveal that an intermediate frame was removed.
        var originalSourceIds = Set(screenshots.map(\.id))
        if let pendingCandidate { originalSourceIds.formUnion(pendingCandidate.sourceScreenshotIds) }
        if let privacyCandidate { originalSourceIds.formUnion(privacyCandidate.sourceScreenshotIds) }
        let sourceStart = min(Int(windowStartTime.timeIntervalSince1970), pendingCandidate?.startTs ?? batchStartTs,
          privacyCandidate?.startTs ?? batchStartTs, previousPrivacy?.startTs ?? batchStartTs)
        let earlierSources = StorageManager.shared.fetchScreenshotsInTimeRange(
          startTs: sourceStart, endTs: batchStartTs - 1)
        let contextRanges = generationContext.existingCards.compactMap {
          try? ClaudeOutputValidator.resolveActivityCardInterval($0, nearest: batchStartTs)
        }
        for frame in earlierSources where contextRanges.contains(where: { $0.contains(frame.capturedAt) })
          || (pendingCandidate.map { frame.capturedAt >= $0.startTs && frame.capturedAt <= $0.endTs } ?? false)
          || (privacyCandidate.map { frame.capturedAt >= $0.startTs && frame.capturedAt <= $0.endTs } ?? false)
          || (previousPrivacy.map { frame.capturedAt >= ($0.startTs ?? batchStartTs) && frame.capturedAt <= ($0.endTs ?? batchStartTs) } ?? false) {
          originalSourceIds.insert(frame.id)
        }
        originalSourceSnapshot = Array(originalSourceIds)
        originalPendingSnapshot = [pendingCandidate?.id, privacyCandidate?.id].compactMap { $0 }
        originalCardSnapshot = exactHistory.compactMap { card in
          guard generationContext.existingCards.contains(where: {
            $0.startTime == card.startTimestamp && $0.endTime == card.endTimestamp
          }) || card.recordId == previousPrivacy?.recordId else { return nil }
          return card.recordId
        }
        let generator: TimelineEvidencePolicy.Generate = configuredContext?.generateTimeline ?? { _, _, _ in
          throw configurationError ?? AIConfiguredRuntimeError.missingRoute
        }
        let result = try await TimelineEvidencePolicy.generate(
          screenshots: screenshots, context: generationContext,
          batchId: batchId, using: generator)
        let cards = result.cards
        let isBackupGenerated = configuredContext?.fallbackState.usedFallback ?? false
        print(
          "🧩 [LLMService] One-step timeline → \(cards.count) cards, "
            + "\(result.observations.count) observations")

        // Model clocks are minute-rounded. Publish only the range bounded by actual
        // captured evidence; keep shorter output as pending facts, outside the timeline.
        let priorPending = StorageManager.shared.pendingTimelineEvidence()
        let sourceSpans = TimelineEvidencePolicy.partition(screenshots)
        let earliest = min(Int(windowStartTime.timeIntervalSince1970), pendingCandidate?.startTs ?? screenshots.first!.capturedAt,
          privacyCandidate?.startTs ?? screenshots.first!.capturedAt, previousPrivacy?.startTs ?? screenshots.first!.capturedAt)
        let evidence = StorageManager.shared.fetchScreenshotsInTimeRange(
          startTs: earliest, endTs: screenshots.last!.capturedAt)
        var publishedCards: [ActivityCardData] = []
        var insertedCardIds: [Int64] = []
        var deletedVideoPaths: [String] = []
        var committed = false
        var didCallCommitHook = false
        for attempt in 0..<3 {
          let minimum = Int(AnalysisPreferences.interval)
          var pendingToSave: [PendingTimelineEvidence] = []
          var pendingToDelete: [Int64] = []
          var replacementGroups: [TimelineCardReplacementGroup] = []
          var currentPublishedCards: [ActivityCardData] = []
          var requiredSourceIds = originalSourceIds
          for (cardIndex, card) in cards.enumerated() {
            let range = try ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: batchStartTs)
            let nextRange = cardIndex + 1 < cards.count
              ? try ClaudeOutputValidator.resolveActivityCardInterval(cards[cardIndex + 1], nearest: batchStartTs) : nil
            let boundaryStartsAnotherCard = nextRange?.lowerBound == range.upperBound
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
            if card.evidenceKind == .privacyRedacted {
              let currentFrames = screenshots.filter {
                $0.isPrivacyRedacted && $0.capturedAt >= range.lowerBound && $0.capturedAt < range.upperBound
              }
              guard let first = currentFrames.first, let last = currentFrames.last else {
                throw ClaudeOutputValidationError.outputOutsideEvidence
              }
              let eligiblePrevious = first.id == screenshots.first?.id
                && previousPrivacy?.startTs.map({ last.capturedAt - $0 <= 3600 }) == true ? previousPrivacy : nil
              let eligiblePending = first.id == screenshots.first?.id
                && privacyCandidate.map({ last.capturedAt - $0.startTs <= 3600 }) == true ? privacyCandidate : nil
              let start = min(first.capturedAt, eligiblePending?.startTs ?? first.capturedAt,
                eligiblePrevious?.startTs ?? first.capturedAt)
              let end = last.capturedAt
              let protectedFrames = evidence.filter {
                $0.isPrivacyRedacted && $0.capturedAt >= start && $0.capturedAt <= end
              }
              guard let sourceFirst = protectedFrames.first, let sourceLast = protectedFrames.last else {
                throw ClaudeOutputValidationError.missingEvidenceCoverage
              }
              for index in protectedFrames.indices.dropFirst() {
                let previous = protectedFrames[protectedFrames.index(before: index)]
                let next = protectedFrames[index]
                let boundary = TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: next.capturedAt)
                guard TimelineEvidencePolicy.captureContinues(history: Array(protectedFrames[..<index]),
                  next: next, recordedContinuity: boundary, privacy: true),
                  previous.capturedDate.getDayInfoFor4AMBoundary().dayString == next.capturedDate.getDayInfoFor4AMBoundary().dayString
                else { throw ClaudeOutputValidationError.cardCoversEvidenceGap(title: card.title) }
              }
              requiredSourceIds.formUnion(protectedFrames.map(\.id))
              let protectedCard = TimelineEvidencePolicy.privacyCard(
                start: TimelineOutputPolicy().formatTimestampForPrompt(start),
                end: TimelineOutputPolicy().formatTimestampForPrompt(end / 60 * 60 + 60))
              for old in priorPending where old.batchId == batchId && old.card.evidenceKind == .privacyRedacted
                && old.id != nil && range.lowerBound <= old.startTs && range.upperBound >= old.endTs {
                if let id = old.id, !pendingToDelete.contains(id) { pendingToDelete.append(id) }
              }
              if let id = eligiblePending?.id, !pendingToDelete.contains(id) { pendingToDelete.append(id) }
              if end - start < minimum {
                var sourceIds = Set(sourceSpans.filter {
                  $0.kind == .privacyRedacted && range.overlaps($0.startTs..<$0.endTs)
                }.flatMap { $0.screenshots.map(\.id) })
                sourceIds.formUnion(protectedFrames.map(\.id))
                if let eligiblePending { sourceIds.formUnion(eligiblePending.sourceScreenshotIds) }
                pendingToSave.append(PendingTimelineEvidence(id: nil, batchId: batchId,
                  startTs: start, endTs: end, card: protectedCard, firstScreenshotId: sourceFirst.id,
                  lastScreenshotId: sourceLast.id, sourceScreenshotIds: Array(sourceIds)))
              } else {
                currentPublishedCards.append(protectedCard)
                replacementGroups.append(TimelineCardReplacementGroup(
                  from: Date(timeIntervalSince1970: Double(start)), to: Date(timeIntervalSince1970: Double(end)),
                  cards: [TimelineCardShell(startTimestamp: protectedCard.startTime, endTimestamp: protectedCard.endTime,
                    category: protectedCard.category, subcategory: "", title: protectedCard.title,
                    summary: protectedCard.summary, detailedSummary: "", distractions: nil, appSites: nil,
                    evidenceKind: .privacyRedacted, exactStartTs: start, exactEndTs: end)]))
              }
              continue
            }
            let matchingHistory = exactHistory.filter { previous in
              guard generationContext.hasContinuousCaptureBeforeBatch,
                let start = previous.startTs, let end = previous.endTs,
                start >= range.lowerBound, end <= range.upperBound,
                previous.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  == card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                previous.evidenceKind == nil || previous.evidenceKind == .visible
              else { return false }
              return generationContext.existingCards.contains {
                $0.startTime == previous.startTimestamp && $0.endTime == previous.endTimestamp
              }
            }
            let matchedPending = pendingCandidate.flatMap { pending -> PendingTimelineEvidence? in
              guard range.lowerBound <= pending.startTs && range.upperBound >= pending.endTs,
                card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  == pending.card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              else { return nil }
              return pending
            }
            let sourceStart = min(screenshots.first!.capturedAt,
              matchedPending?.startTs ?? screenshots.first!.capturedAt,
              matchingHistory.compactMap(\.startTs).min() ?? screenshots.first!.capturedAt)
            let supported = evidence.filter {
              !$0.isPrivacyRedacted && $0.capturedAt >= max(range.lowerBound, sourceStart)
                && ($0.capturedAt < range.upperBound || (!boundaryStartsAnotherCard && $0.capturedAt == range.upperBound))
            }
            guard let first = supported.first, let last = supported.last else {
              throw ClaudeOutputValidationError.missingEvidenceCoverage
            }
            for index in supported.indices.dropFirst() {
              let previous = supported[supported.index(before: index)]
              let next = supported[index]
              let stop = TimelineCaptureBoundaries.shared.continuity(from: previous.capturedAt, to: next.capturedAt)
              let sameDay = previous.capturedDate.getDayInfoFor4AMBoundary().dayString
                == next.capturedDate.getDayInfoFor4AMBoundary().dayString
              let sameCapture = TimelineEvidencePolicy.captureContinues(
                history: Array(supported[..<index]), next: next, recordedContinuity: stop)
              guard sameDay && sameCapture else { throw ClaudeOutputValidationError.cardCoversEvidenceGap(title: card.title) }
            }
            requiredSourceIds.formUnion(supported.map(\.id))
            let firstId = first.id, lastId = last.id
            let start = min(first.capturedAt, matchingHistory.compactMap(\.startTs).min() ?? first.capturedAt)
            let end = last.capturedAt
            for old in priorPending where old.batchId == batchId && old.id != nil
              && range.lowerBound <= old.startTs && range.upperBound >= old.endTs {
              pendingToDelete.append(old.id!)
            }
            if let pending = pendingCandidate, let id = pending.id,
              range.lowerBound <= pending.startTs && range.upperBound >= pending.endTs,
              card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == pending.card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
              if !pendingToDelete.contains(id) { pendingToDelete.append(id) }
            }
            if end - start < minimum {
              // Retain this provider input span, not unrelated privacy or visible
              // spans that happened to share the surrounding batch.
              var pendingSourceIds = Set(sourceSpans.filter {
                $0.kind == .visible && range.overlaps($0.startTs..<$0.endTs)
              }.flatMap { $0.screenshots.map(\.id) })
              pendingSourceIds.formUnion(supported.map(\.id))
              if let matchedPending { pendingSourceIds.formUnion(matchedPending.sourceScreenshotIds) }
              for frame in earlierSources where contextRanges.contains(where: { $0.contains(frame.capturedAt) }) {
                pendingSourceIds.insert(frame.id)
              }
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
                endTimestamp: TimelineOutputPolicy().formatTimestampForPrompt(end / 60 * 60 + 60),
                category: card.category, subcategory: card.subcategory, title: card.title,
                summary: card.summary, detailedSummary: card.detailedSummary,
                distractions: card.distractions, appSites: card.appSites,
                isBackupGenerated: isBackupGenerated ? true : nil, evidenceKind: card.evidenceKind,
                exactStartTs: start, exactEndTs: end)]))
          }
          do {
            if !didCallCommitHook { beforeTimelineCommit?(); didCallCommitHook = true }
            replacingTimelineCards = true
            let saved = try StorageManager.shared.replaceTimelineCardGroups(
              replacementGroups, batchId: batchId,
              keepingNewerBatchesCardsStartingAfter: batchStartTime,
              pendingToSave: pendingToSave, pendingToDelete: pendingToDelete, enforceMinimum: true,
              markBatchAnalyzed: true, replacementObservations: result.observations,
              requiredScreenshotIds: Array(requiredSourceIds),
              requiredPendingIds: [pendingCandidate?.id, privacyCandidate?.id].compactMap { $0 },
              requiredCardIds: originalCardSnapshot)
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

        let providerWasUsed = sourceSpans.contains { $0.kind == .visible }
        // Local privacy handling does not prove a failed provider has recovered.
        if providerWasUsed { TimelineFailureToastCenter.hide() }

        completion(.success(ProcessedBatchResult(cards: publishedCards, cardIds: insertedCardIds,
          providerWasUsed: providerWasUsed)))

      } catch {
        if !holdsTimelineCardGenerationGate {
          await Self.timelineCardGenerationGate.acquire()
          holdsTimelineCardGenerationGate = true
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

        // Mark batch as failed. The raw error stays in the batch row for debugging;
        // the user only ever sees the classifier's plain-language copy.
        StorageManager.shared.updateBatch(
          batchId, status: "failed", reason: error.localizedDescription)

        // A failed replacement has rolled back; no second write may change its history.
        if replacingTimelineCards {
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
          guard span.kind != .privacyRedacted else { return nil }
          let start = Date(timeIntervalSince1970: Double(span.startTs))
          let end = Date(timeIntervalSince1970: Double(span.endTs))
          return TimelineCardReplacementGroup(from: start, to: end, cards: [
            createErrorCard(batchStartTime: start, batchEndTime: end,
              message: failureClassification.cardMessage(fallbackProviderLabel: primaryProviderLabel))])
        }

        // Privacy is a local fact even when a visible provider fails. Keep it
        // pending with exact boundaries; the manager can publish it once it
        // qualifies, without sending protected frames to any provider.
        let localPrivacy = Self.localPrivacyPending(batchId: batchId, screenshots: failedScreenshots)
        let savedFailure = try? StorageManager.shared.replaceTimelineCardGroups(
          failureGroups, batchId: batchId, keepingNewerBatchesCardsStartingAfter: batchStartDate,
          pendingToSave: localPrivacy.records, pendingToDelete: localPrivacy.consumed,
          requiredScreenshotIds: originalSourceSnapshot + localPrivacy.sources,
          requiredPendingIds: Array(Set(originalPendingSnapshot + localPrivacy.consumed)),
          requiredCardIds: Array(Set(originalCardSnapshot + localPrivacy.cards)))
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
