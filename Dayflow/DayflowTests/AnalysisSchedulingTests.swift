import Foundation
import XCTest

@testable import Dayflow

@MainActor
final class AnalysisSchedulingTests: XCTestCase {
  private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath,
    line: UInt = #line) async {
    for _ in 0..<300 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Scheduler did not reach expected state", file: file, line: line)
  }

  func testSuspendedHistoryAllowsLiveToStartAndFinishWhilePreservingDeadline() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "failed", failedCard: true)
    store.addBatch(2, status: "failed", failedCard: true)
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 && manager.liveBatchIsAnalyzing }
    let firstLive = service.ids[0]
    service.finish(firstLive)
    await waitUntil { service.ids.count == 2 && manager.isRecoveringEarlierBatches }
    XCTAssertEqual(service.ids[1], 1)

    store.addLive(start: clock.timestamp - 300)
    store.addLive(start: clock.timestamp - 60, complete: false)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 3 && manager.liveBatchIsAnalyzing
      && manager.nextCardAnalysisDate != nil }
    XCTAssertTrue(manager.isRecoveringEarlierBatches)
    XCTAssertEqual(manager.nextCardAnalysisDate,
      Date(timeIntervalSince1970: Double(clock.timestamp)))
    XCTAssertNotEqual(service.ids[2], 2)
    service.finish(service.ids[2])
    await waitUntil { !manager.liveBatchIsAnalyzing }
    XCTAssertTrue(manager.isRecoveringEarlierBatches, "History remains suspended while live finishes")
    XCTAssertEqual(service.ids.count, 3)
    service.finish(1)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    XCTAssertEqual(service.ids.count, 3, "Catch-up cannot chain around its global cooldown")
    clock.advance(61)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 4 }
    XCTAssertEqual(service.ids[3], 2)
    service.finish(2)
    await waitUntil { !manager.isRecoveringEarlierBatches }
  }

  func testSuspendedLiveAllowsHistoryButNeitherLaneStartsASecondBatch() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "failed", failedCard: true)
    store.addBatch(2, status: "failed", failedCard: true)
    store.addLive(start: clock.timestamp - 900)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    // Queue two live batches before the first success enables recovery.
    store.addLive(start: clock.timestamp - 600)
    store.addLive(start: clock.timestamp - 300)
    manager.triggerAnalysisNow()
    await waitUntil { manager.liveBatchIsQueued }
    service.finish(service.ids[0])
    await waitUntil { service.ids.count == 3 && manager.liveBatchIsAnalyzing
      && manager.isRecoveringEarlierBatches }
    guard let secondLive = service.ids.dropFirst().first(where: { $0 != 1 }) else {
      XCTFail("Second live batch did not start")
      return
    }
    XCTAssertTrue(service.ids.contains(1))
    // Advancing the clock and polling cannot overfill either running lane.
    clock.advance(300)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.count, 3)
    XCTAssertTrue(manager.liveBatchIsQueued)
    service.finish(1)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    clock.advance(61)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 4 }
    XCTAssertEqual(service.ids.last, 2, "History starts while the live request remains suspended")
    service.finish(2)
    service.finish(secondLive)
    await waitUntil { service.ids.count == 5 }
    service.finish(service.ids[4])
    await waitUntil { !manager.liveBatchIsAnalyzing && !manager.isRecoveringEarlierBatches }
  }

  func testManualRequestsShareRetryLaneAndReserveBeforeResetWithoutBlockingLive() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    for id: Int64 in 1...3 { store.addBatch(id, status: "failed", failedCard: true) }
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    store.beforeReset = { [weak manager] id in
      XCTAssertEqual(manager?.isBatchInFlight(id), true, "Claim must precede every reset")
    }
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    service.finish(service.ids[0])
    await waitUntil { service.ids.count == 2 }
    manager.setManualRetryRunning(true)
    let manualCompleted = expectation(description: "manual retries completed")
    manualCompleted.expectedFulfillmentCount = 2
    for id: Int64 in 2...3 {
      manager.reprocessBatch(id, stepHandler: { _ in }) { result in
        if case .failure(let error) = result { XCTFail("Manual retry failed: \(error)") }
        manualCompleted.fulfill()
      }
    }
    let duplicate = expectation(description: "queued duplicate rejected before reset")
    manager.reprocessBatch(2, stepHandler: { _ in }) { result in
      guard case .failure(let error) = result else { XCTFail("Duplicate accepted"); return }
      XCTAssertEqual((error as NSError).code, 5)
      duplicate.fulfill()
    }
    await fulfillment(of: [duplicate], timeout: 3)
    XCTAssertTrue(manager.isBatchInFlight(2), "Queued manual retry owns its claim")
    XCTAssertEqual(store.resetIDs, [1], "Queued requests must not reset before their turn")
    XCTAssertEqual(service.ids.count, 2)
    store.addLive(start: clock.timestamp - 300)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 3 && manager.liveBatchIsAnalyzing }
    service.finish(service.ids[2])
    await waitUntil { !manager.liveBatchIsAnalyzing }
    service.finish(1)
    await waitUntil { service.ids.count == 4 }
    XCTAssertEqual(service.ids.last, 2)
    XCTAssertEqual(store.resetIDs, [1, 2])
    clock.advance(300)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.count, 4)
    service.finish(2)
    await waitUntil { service.ids.count == 5 }
    XCTAssertEqual(service.ids.last, 3)
    service.finish(3)
    await fulfillment(of: [manualCompleted], timeout: 3)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    XCTAssertEqual(store.resetIDs, [1, 2, 3])
  }

  func testUncommittedLiveConflictWithoutFailedCardRetriesFreshAndCompletes() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    let id = service.ids[0]
    XCTAssertEqual(store.allBatches().first { $0.id == id }?.status, "processing")
    XCTAssertTrue(store.fetchTimelineCards(forDay: "unused").isEmpty)
    service.finish(id, error: TimelineCardReplacementError.timelineChanged)
    await waitUntil { !manager.liveBatchIsAnalyzing }
    XCTAssertEqual(store.allBatches().first { $0.id == id }?.status, "pending_conflict")
    XCTAssertTrue(store.fetchTimelineCards(forDay: "unused").isEmpty)
    XCTAssertFalse(manager.isBatchInFlight(id))
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids, [id], "Conflict must defer rather than rebase immediately")
    clock.advance(61)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 2 && manager.isRecoveringEarlierBatches }
    XCTAssertEqual(service.ids, [id, id], "Retry must make a fresh model request for the same batch")
    XCTAssertFalse(manager.liveBatchIsAnalyzing)
    XCTAssertEqual(store.resetIDs, [id])
    XCTAssertEqual(store.allBatches().first { $0.id == id }?.status, "processing")
    service.finish(id)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    XCTAssertEqual(store.allBatches().first { $0.id == id }?.status, "completed")
    XCTAssertFalse(manager.isBatchInFlight(id))
  }

  func testPendingConflictRetriesKeepExponentialBackoffAndThreeAttemptBudget() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    let id = service.ids[0]
    service.finish(id, error: TimelineCardReplacementError.timelineChanged)
    await waitUntil { !manager.liveBatchIsAnalyzing }
    for attempt in 1...3 {
      let delay = 60 * pow(2, Double(max(0, attempt - 2)))
      clock.advance(delay - 1)
      manager.triggerAnalysisNow()
      try? await Task.sleep(nanoseconds: 50_000_000)
      XCTAssertEqual(service.ids.count, attempt, "Retry must respect its cooldown")
      clock.advance(2)
      manager.triggerAnalysisNow()
      await waitUntil { service.ids.count == attempt + 1 && manager.isRecoveringEarlierBatches }
      XCTAssertEqual(service.ids.last, id)
      service.finish(id, error: TimelineCardReplacementError.timelineChanged)
      await waitUntil { !manager.isRecoveringEarlierBatches }
      XCTAssertEqual(store.allBatches().first { $0.id == id }?.status, "pending_conflict")
    }
    clock.advance(1000)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids, [id, id, id, id], "Live attempt plus at most three automatic retries")
    XCTAssertTrue(store.fetchTimelineCards(forDay: "unused").isEmpty)
  }

  func testTimelineConflictPreservesCommittedBatchStatusAndBothLanesContinue() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "failed", failedCard: true)
    store.addBatch(2, status: "failed", failedCard: true)
    store.addLive(start: clock.timestamp - 900)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    service.finish(service.ids[0])
    await waitUntil { service.ids.count == 2 }
    store.addLive(start: clock.timestamp - 600)
    store.addLive(start: clock.timestamp - 300)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 3 && manager.liveBatchIsQueued }
    let conflictingLive = service.ids[2]
    // Simulate another commit winning before these model requests return.
    store.updateBatchStatus(batchId: conflictingLive, status: "completed")
    store.updateBatchStatus(batchId: 1, status: "completed")
    service.finish(conflictingLive, error: TimelineCardReplacementError.timelineChanged)
    await waitUntil { service.ids.count == 4 }
    XCTAssertEqual(store.allBatches().first { $0.id == conflictingLive }?.status, "completed")
    XCTAssertFalse(manager.isBatchInFlight(conflictingLive))
    service.finish(1, error: TimelineCardReplacementError.timelineChanged)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    XCTAssertEqual(store.allBatches().first { $0.id == 1 }?.status, "completed")
    XCTAssertFalse(manager.isBatchInFlight(1))
    clock.advance(61)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 5 }
    XCTAssertEqual(service.ids.last, 2, "Local conflicts must not pause recovery")
    XCTAssertTrue(manager.liveBatchIsAnalyzing)
    XCTAssertEqual(service.ids.filter { $0 == conflictingLive }.count, 1, "No automatic rebase")
    service.finish(2)
    service.finish(service.ids[3])
    await waitUntil { !manager.liveBatchIsAnalyzing && !manager.isRecoveringEarlierBatches }
  }

  func testRetryBudgetBackoffAndFairnessDoNotResetOnSuccess() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "failed", failedCard: true)
    store.addBatch(2, status: "failed", failedCard: true)
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    service.finish(service.ids[0])
    await waitUntil { service.ids.count == 2 }
    XCTAssertEqual(service.ids.last, 1)
    service.finish(1, error: ClaudeOutputValidationError.missingEvidenceCoverage)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.count, 2)
    clock.advance(61)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 3 }
    XCTAssertEqual(service.ids.last, 2, "Untouched failures precede a repeated old failure")
    service.finish(2)
    await waitUntil { !manager.isRecoveringEarlierBatches }

    // Simulate a stale failed placeholder/status reappearing after success.
    // A successful automatic attempt must not erase its session budget.
    for expectedCount in 4...5 {
      store.updateBatchStatus(batchId: 1, status: "failed")
      clock.advance(300)
      manager.triggerAnalysisNow()
      await waitUntil { service.ids.count == expectedCount }
      XCTAssertEqual(service.ids.last, 1)
      service.finish(1)
      await waitUntil { !manager.isRecoveringEarlierBatches }
    }
    store.updateBatchStatus(batchId: 1, status: "failed")
    clock.advance(300)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.filter { $0 == 1 }.count, 3)
    XCTAssertEqual(service.ids.count, 5)
  }

  func testRepeatedOutputFailureUsesExponentialCooldownAndThreeAttemptLimit() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "failed", failedCard: true)
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    service.finish(service.ids[0])
    await waitUntil { service.ids.count == 2 }
    service.finish(1, error: ClaudeOutputValidationError.missingEvidenceCoverage)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    clock.advance(61)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 3 }
    service.finish(1, error: ClaudeOutputValidationError.missingEvidenceCoverage)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    clock.advance(61)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.count, 3, "Second failure requires 120 seconds, not just global 60")
    clock.advance(60)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 4 }
    service.finish(1, error: ClaudeOutputValidationError.missingEvidenceCoverage)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    clock.advance(300)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.filter { $0 == 1 }.count, 3)
  }

  func testManualRetryPausesHistoricalSchedulingButNotLiveWork() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "failed", failedCard: true)
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.setManualRetryRunning(true)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    service.finish(service.ids[0])
    await waitUntil { !manager.liveBatchIsAnalyzing }
    XCTAssertEqual(service.ids.count, 1)
    manager.setManualRetryRunning(false)
    await waitUntil { service.ids.count == 2 }
    XCTAssertEqual(service.ids.last, 1)
    service.finish(1)
    await waitUntil { !manager.isRecoveringEarlierBatches }
  }

  func testServiceFailurePausesRecoveryUntilNonCatchUpProviderSuccess() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "failed", failedCard: true)
    store.addBatch(2, status: "failed", failedCard: true)
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    service.finish(service.ids[0])
    await waitUntil { service.ids.count == 2 }
    service.finish(1, error: URLError(.timedOut))
    await waitUntil { !manager.isRecoveringEarlierBatches }
    clock.advance(300)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.count, 2)
    store.addLive(start: clock.timestamp - 120)
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 3 }
    service.finish(service.ids[2])
    await waitUntil { service.ids.count == 4 }
    XCTAssertEqual(service.ids.last, 2)
    service.finish(2)
    await waitUntil { !manager.isRecoveringEarlierBatches }
  }

  func testOrphanProcessingRequiresFailedCardAndDuplicateRetryCannotResetActiveBatch() async {
    let store = SchedulerStorage()
    let service = SchedulerService()
    let clock = SchedulerClock()
    store.addBatch(1, status: "processing", failedCard: true)
    store.addBatch(2, status: "processing", failedCard: false)
    store.addLive(start: clock.timestamp - 600)
    let manager = AnalysisManager(store: store, llmService: service, now: clock.read,
      pendingEvidence: { [] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { service.ids.count == 1 }
    service.finish(service.ids[0])
    await waitUntil { service.ids.count == 2 }
    XCTAssertEqual(service.ids.last, 1)
    XCTAssertTrue(manager.isBatchInFlight(1))
    let duplicate = expectation(description: "duplicate rejected")
    manager.reprocessBatch(1, stepHandler: { _ in }) { result in
      guard case .failure(let error) = result else { XCTFail("Duplicate accepted"); return }
      XCTAssertEqual((error as NSError).code, 5)
      duplicate.fulfill()
    }
    await fulfillment(of: [duplicate], timeout: 3)
    XCTAssertEqual(store.resetIDs, [1], "Duplicate must not reset the running batch")
    XCTAssertEqual(store.allBatches().first { $0.id == 1 }?.status, "processing")
    service.finish(1)
    await waitUntil { !manager.isRecoveringEarlierBatches }
    clock.advance(300)
    manager.triggerAnalysisNow()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(service.ids.count, 2, "Ordinary orphan processing is not a failed-card recovery")
    XCTAssertFalse(manager.isBatchInFlight(1))
  }

  func testPendingDurationIsInjectedAndDoesNotPretendToBeLiveModelWork() async {
    let clock = SchedulerClock()
    let card = ActivityCardData(startTime: "10:00", endTime: "10:01", category: "Work",
      subcategory: "", title: "Pending", summary: "", detailedSummary: "",
      distractions: nil, appSites: nil)
    let duration = min(30, Int(AnalysisPreferences.interval) - 1)
    let pending = PendingTimelineEvidence(id: nil, batchId: 1,
      startTs: clock.timestamp - duration, endTs: clock.timestamp, card: card,
      firstScreenshotId: 1, lastScreenshotId: 2)
    let manager = AnalysisManager(store: SchedulerStorage(), llmService: SchedulerService(),
      now: clock.read, pendingEvidence: { [pending] }, evaluate: { _ in })
    manager.triggerAnalysisNow()
    await waitUntil { manager.latestPendingEventDuration != nil }
    XCTAssertEqual(manager.latestPendingEventDuration, TimeInterval(duration))
    XCTAssertFalse(manager.liveBatchIsAnalyzing)
    XCTAssertFalse(manager.liveBatchIsQueued)
    XCTAssertNil(manager.nextCardAnalysisDate)
    clock.advance(86401)
    manager.triggerAnalysisNow()
    await waitUntil { manager.latestPendingEventDuration == nil }
  }
}

private final class SchedulerClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  var timestamp: Int { Int(read().timeIntervalSince1970) }
  func read() -> Date { lock.withLock { date } }
  func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private final class SchedulerService: LLMServicing, @unchecked Sendable {
  private let lock = NSLock()
  private var requested: [Int64] = []
  private var completions: [Int64: (Result<ProcessedBatchResult, Error>) -> Void] = [:]
  var ids: [Int64] { lock.withLock { requested } }
  var batchingConfig: BatchingConfig {
    .init(targetDuration: 60, maxGap: 120, cardLookbackDuration: 600)
  }
  func generateTargetEvaluation(prompt: String) async throws -> String { "" }
  func processBatch(_ batchId: Int64, progressHandler: ((LLMProcessingStep) -> Void)?,
    completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void) {
    lock.withLock {
      requested.append(batchId)
      completions[batchId] = completion
    }
  }
  func finish(_ id: Int64, error: Error? = nil) {
    let completion = lock.withLock { completions.removeValue(forKey: id) }
    XCTAssertNotNil(completion)
    if let error { completion?(.failure(error)) }
    else { completion?(.success(.init(cards: [], cardIds: [], providerWasUsed: true))) }
  }
}

private final class SchedulerStorage: StorageManaging, @unchecked Sendable {
  private typealias Batch = (id: Int64, start: Int, end: Int, status: String)
  private let lock = NSRecursiveLock()
  private var batches: [Batch] = []
  private var frames: [Int64: [Screenshot]] = [:]
  private var unprocessed: [Screenshot] = []
  private var failedIDs = Set<Int64>()
  private var resets: [Int64] = []
  private var nextID: Int64 = 100
  var resetIDs: [Int64] { lock.withLock { resets } }
  var beforeReset: ((Int64) -> Void)?
  private func screenshots(start: Int, complete: Bool = true) -> [Screenshot] {
    (complete ? [0, 60] : [0]).map { offset in
      Screenshot(id: Int64(start + offset), capturedAt: start + offset,
        filePath: "/dev/null", fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false)
    }
  }
  func addBatch(_ id: Int64, status: String, failedCard: Bool) {
    lock.withLock {
      let start = Int(Date().timeIntervalSince1970) - 3600 + Int(id) * 120
      batches.append((id, start, start + 60, status))
      frames[id] = screenshots(start: start)
      if failedCard { failedIDs.insert(id) }
    }
  }
  func addLive(start: Int, complete: Bool = true) {
    lock.withLock { unprocessed += screenshots(start: start, complete: complete) }
  }
  func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)] {
    lock.withLock { batches }
  }
  func updateBatchStatus(batchId: Int64, status: String) {
    lock.withLock {
      if let index = batches.firstIndex(where: { $0.id == batchId }) { batches[index].status = status }
    }
  }
  func markBatchFailed(batchId: Int64, reason: String) {
    lock.withLock { failedIDs.insert(batchId); updateBatchStatus(batchId: batchId, status: "failed") }
  }
  func resetBatchStatuses(forBatchIds batchIds: [Int64]) -> [Int64] {
    lock.withLock {
      batchIds.forEach { beforeReset?($0) }
      resets += batchIds
      batchIds.forEach { updateBatchStatus(batchId: $0, status: "pending") }
      return batchIds
    }
  }
  func fetchUnprocessedScreenshots(since oldestTimestamp: Int) -> [Screenshot] {
    lock.withLock { unprocessed.filter { $0.capturedAt >= oldestTimestamp } }
  }
  func saveBatchWithScreenshots(startTs: Int, endTs: Int, screenshotIds: [Int64]) -> Int64? {
    lock.withLock {
      nextID += 1
      frames[nextID] = unprocessed.filter { screenshotIds.contains($0.id) }
      unprocessed.removeAll { screenshotIds.contains($0.id) }
      batches.append((nextID, startTs, endTs, "pending"))
      return nextID
    }
  }
  func screenshotsForBatch(_ batchId: Int64) -> [Screenshot] { lock.withLock { frames[batchId] ?? [] } }
  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int) -> [Screenshot] { [] }
  func fetchTimelineCards(forDay day: String) -> [TimelineCard] {
    lock.withLock {
      failedIDs.map { id in
        TimelineCard(recordId: id, batchId: id, startTimestamp: "10:00", endTimestamp: "10:01",
          category: "System", subcategory: "", title: "Processing failed", summary: "",
          detailedSummary: "", day: day, distractions: nil, videoSummaryURL: nil,
          otherVideoSummaryURLs: nil, appSites: nil)
      }
    }
  }
  func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard] { [] }
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? { nil }
  func fetchTimelineCardEndingLast(startingBefore: Date, excludingBatchId: Int64) -> TimelineCardWithTimestamps? { nil }
  func saveIdleBatchCard(_ card: TimelineCardShell, startTs: Int, endTs: Int, batchId: Int64,
    extendingCardId: Int64?) -> (cardId: Int64?, deletedVideoPaths: [String]) { (nil, []) }
  func fetchMostRecentDayGoalPlan(beforeOrOn day: String) -> DayGoalPlan? { nil }
  func saveDayGoalPlan(_ plan: DayGoalPlan) {}
  func deleteObservations(forBatchIds batchIds: [Int64]) {}
}
