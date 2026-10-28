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

  init(
    loadConfiguration: @escaping () throws -> AIConfiguration = {
      try AIConfigurationStore.shared.load()
    },
    configuredText: ((String, AIFeature) async throws -> String)? = nil
  ) {
    self.loadConfiguration = loadConfiguration
    self.configuredText = configuredText
  }

  private static let timelineCardGenerationGate = TimelineCardGenerationGate()
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
      generateTimeline: { screenshots, context, batchID in
        try await runtime.withConfiguration(feature: .timeline) { provider in
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
      let configuredContext: TimelineProviderContext
      do {
        configuredContext = try makeConfiguredTimelineContext(loadConfiguration())
      } catch {
        completion(.failure(error))
        return
      }
      let primaryProviderID = configuredContext.id
      let primaryProviderLabel = configuredContext.providerLabel
      var lastProcessingStep: LLMProcessingStep?
      print(
        "🧭 [LLMService] processBatch selected primary=\(primaryProviderID.analyticsName) "
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
            card.category != "System"
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
              appSites: card.appSites
            )
          }

          return ActivityGenerationContext(
            batchObservations: batchObservations,
            existingCards: existingActivityCards,
            currentTime: currentTime,
            categories: CategoryStore.descriptorsForLLM(),
            hasPreviousCardWithinFiveMinutes: hasPreviousCardWithinFiveMinutes
          )
        }

        lastProcessingStep = .generatingCards
        await MainActor.run {
          progressHandler?(.generatingCards)
        }

        // Timeline reads, generation, and replacement form one serialized rewrite.
        await Self.timelineCardGenerationGate.acquire()
        holdsTimelineCardGenerationGate = true

        let result = try await configuredContext.generateTimeline(
          screenshots, makeGenerationContext(batchObservations: []), batchId)
        StorageManager.shared.saveObservations(batchId: batchId, observations: result.observations)
        let cards = result.cards
        let rewriteSpan = result.rewriteSpan
        let isBackupGenerated = configuredContext.fallbackState.usedFallback
        print(
          "🧩 [LLMService] One-step timeline → \(cards.count) cards, "
            + "\(result.observations.count) observations")

        // Replace old cards with new ones in the time range
        let replacementRange = Self.cardReplacementRange(
          rewriteSpan: rewriteSpan,
          windowStartTime: windowStartTime,
          batchEndTime: currentTime
        )
        // A model shown only connected cards never saw cards that newer batches started after
        // this one began, so a retry finishing late must not delete them. Providers shown the
        // whole window saw those cards and rewrote them, so theirs are replaced as before.
        let keepNewerCardsAfter = rewriteSpan == nil ? nil : batchStartTime
        let (insertedCardIds, deletedVideoPaths) = StorageManager.shared
          .replaceTimelineCardsInRange(
            from: replacementRange.from,
            to: replacementRange.to,
            with: cards.map { card in
              TimelineCardShell(
                startTimestamp: card.startTime,
                endTimestamp: card.endTime,
                category: card.category,
                subcategory: card.subcategory,
                title: card.title,
                summary: card.summary,
                detailedSummary: card.detailedSummary,
                distractions: card.distractions,
                appSites: card.appSites,
                isBackupGenerated: isBackupGenerated ? true : nil
              )
            },
            batchId: batchId,
            keepingNewerBatchesCardsStartingAfter: keepNewerCardsAfter
          )

        // Clean up deleted video files
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

        // Whatever the failure card asked the user to fix is working again.
        TimelineFailureToastCenter.hide()

        completion(.success(ProcessedBatchResult(cards: cards, cardIds: insertedCardIds)))

      } catch {
        if !holdsTimelineCardGenerationGate {
          await Self.timelineCardGenerationGate.acquire()
          holdsTimelineCardGenerationGate = true
        }

        print("Error processing batch: \(error)")
        if let ns = error as NSError?, ns.domain == "GeminiError" {
          print("🔎 GEMINI DEBUG: NSError.userInfo=\(ns.userInfo)")
        }

        let failureClassification = TimelineFailureClassifier.classify(error)

        // Track analysis batch failed

        // Mark batch as failed. The raw error stays in the batch row for debugging;
        // the user only ever sees the classifier's plain-language copy.
        StorageManager.shared.updateBatch(
          batchId, status: "failed", reason: error.localizedDescription)

        emitTimelineFailureToast(
          classification: failureClassification,
          operation: lastProcessingStep,
          error: error,
          primaryProvider: primaryProviderID.analyticsName,
          primaryProviderLabel: primaryProviderLabel,
          backupProvider: nil,
          backupProviderLabel: nil,
          backupConfigured: false,
          batchId: batchId
        )

        // Create an error card for the failed time period
        let batchStartDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))
        let batchEndDate = Date(timeIntervalSince1970: TimeInterval(batchEndTs))

        let errorCard = createErrorCard(
          batchStartTime: batchStartDate,
          batchEndTime: batchEndDate,
          message: failureClassification.cardMessage(fallbackProviderLabel: primaryProviderLabel)
        )

        // Replace any existing cards in this time range with the error card
        // This matches the happy path behavior and prevents duplicates. A retry can fail after
        // newer batches succeeded, so their cards stay.
        let (insertedCardIds, deletedVideoPaths) = StorageManager.shared
          .replaceTimelineCardsInRange(
            from: batchStartDate,
            to: batchEndDate,
            with: [errorCard],
            batchId: batchId,
            keepingNewerBatchesCardsStartingAfter: batchStartDate
          )

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
      summary: "\(message) Your recording is saved.",
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
