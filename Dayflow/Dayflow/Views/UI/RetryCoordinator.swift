import Foundation

@MainActor
final class RetryCoordinator: ObservableObject {
  enum Status: Equatable {
    case queued(position: Int, total: Int)
    case running(step: LLMProcessingStep)
    case failed
    case stopped
    case done
  }

  @Published private(set) var statuses: [Int64: Status] = [:]
  @Published private(set) var isRunning = false
  @Published private(set) var activeBatchId: Int64? = nil
  @Published private var dotTick: Int = 0

  typealias Reprocess = (Int64, @escaping (LLMProcessingStep) -> Void,
    @escaping (Result<Void, Error>) -> Void) -> Void

  private let batchIDsForDay: @Sendable (String) -> [Int64]
  private let reprocess: Reprocess
  private let setManualRetryRunning: (Bool) -> Void
  private var retryDay = ""
  private var dotTimer: Timer?

  init(batchIDsForDay: (@Sendable (String) -> [Int64])? = nil,
    reprocess: Reprocess? = nil, setManualRetryRunning: ((Bool) -> Void)? = nil) {
    self.batchIDsForDay = batchIDsForDay ?? Self.failedBatchIds
    self.reprocess = reprocess ?? { id, progress, completion in
      AnalysisManager.shared.reprocessBatch(id, stepHandler: progress, completion: completion)
    }
    self.setManualRetryRunning = setManualRetryRunning ?? {
      AnalysisManager.shared.setManualRetryRunning($0)
    }
  }

  func statusLine(for batchId: Int64?) -> String? {
    guard let batchId, let status = statuses[batchId] else { return nil }

    switch status {
    case .queued(let position, let total):
      return "Status: Queued (\(position) of \(total))"
    case .running(let step):
      return "Status: Reprocessing - Step: \(stepLabel(step))\(dots)"
    case .failed:
      return String(localized: "Status: This retry failed")
    case .stopped:
      return String(localized: "Status: Queue paused - earlier retry failed")
    case .done:
      return nil
    }
  }

  func statusLine(for batchIds: [Int64]) -> String? {
    let batchIds = Array(Set(batchIds))
    guard !batchIds.isEmpty else { return nil }
    if batchIds.count == 1 {
      return statusLine(for: batchIds[0])
    }

    if let activeBatchId, batchIds.contains(activeBatchId) {
      return statusLine(for: activeBatchId)
    }

    let groupStatuses = batchIds.compactMap { statuses[$0] }
    guard !groupStatuses.isEmpty else { return nil }

    if groupStatuses.contains(.failed) {
      return String(localized: "Status: This retry failed")
    }

    let queued = groupStatuses.compactMap { status -> (position: Int, total: Int)? in
      guard case .queued(let position, let total) = status else { return nil }
      return (position, total)
    }

    if let first = queued.min(by: { $0.position < $1.position }),
      let last = queued.max(by: { $0.position < $1.position })
    {
      if first.position == last.position {
        return "Status: Queued (\(first.position) of \(first.total))"
      }
      return "Status: Queued (\(first.position)-\(last.position) of \(first.total))"
    }

    if groupStatuses.contains(.stopped) {
      return String(localized: "Status: Queue paused - earlier retry failed")
    }

    return nil
  }

  func isActive(batchId: Int64?) -> Bool {
    guard let batchId else { return false }
    return activeBatchId == batchId
  }

  func isActive(batchIds: [Int64]) -> Bool {
    guard let activeBatchId else { return false }
    return batchIds.contains(activeBatchId)
  }

  func startRetry(for dayString: String, onBatchCompleted: @escaping (Int64) -> Void) {
    guard !isRunning else { return }
    isRunning = true
    retryDay = dayString
    setManualRetryRunning(true)

    let load = batchIDsForDay
    Task.detached {
      let batchIds = load(dayString)
      await MainActor.run {
        self.beginQueue(batchIds: batchIds, onBatchCompleted: onBatchCompleted)
      }
    }
  }

  nonisolated private static func failedBatchIds(for dayString: String) -> [Int64] {
    let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
    var seen = Set<Int64>()
    var ordered: [Int64] = []

    for card in cards.sorted(by: { ($0.startTs ?? 0) < ($1.startTs ?? 0) }) {
      // A batch already being retried automatically still shows its failed
      // card; skip it so two runs don't race.
      guard
        TimelineActivityLoader.isRetryableFailedCard(card, storageManager: StorageManager.shared),
        let batchId = card.batchId,
        !AnalysisManager.shared.isBatchInFlight(batchId)
      else { continue }
      guard !seen.contains(batchId) else { continue }
      seen.insert(batchId)
      ordered.append(batchId)
    }

    return ordered
  }

  private func beginQueue(batchIds: [Int64], onBatchCompleted: @escaping (Int64) -> Void) {
    statuses = [:]
    activeBatchId = nil
    guard !batchIds.isEmpty else {
      finishRun()
      return
    }

    let total = batchIds.count
    for (index, batchId) in batchIds.enumerated() {
      statuses[batchId] = .queued(position: index + 1, total: total)
    }

    processNext(index: 0, batchIds: batchIds, onBatchCompleted: onBatchCompleted)
  }

  private func processNext(
    index: Int, batchIds: [Int64], onBatchCompleted: @escaping (Int64) -> Void
  ) {
    guard index < batchIds.count else {
      finishRun()
      return
    }

    let batchId = batchIds[index]
    // Successful neighboring batches can replace failed placeholders. Re-check
    // immediately before dispatch, rather than replaying the stale day snapshot.
    guard batchIDsForDay(retryDay).contains(batchId) else {
      statuses[batchId] = .done
      processNext(index: index + 1, batchIds: batchIds, onBatchCompleted: onBatchCompleted)
      return
    }
    activeBatchId = batchId
    statuses[batchId] = .running(step: .transcribing)
    startDotTimerIfNeeded()

    reprocess(
      batchId,
      { [weak self] step in
        self?.statuses[batchId] = .running(step: step)
      },
      { [weak self, setManualRetryRunning] result in
        guard let self else {
          setManualRetryRunning(false)
          return
        }

        switch result {
        case .success:
          self.statuses[batchId] = .done
          onBatchCompleted(batchId)
          self.processNext(index: index + 1, batchIds: batchIds, onBatchCompleted: onBatchCompleted)
        case .failure(let error):
          self.statuses[batchId] = .failed
          // Refresh the error details too; otherwise the UI keeps showing the
          // previous network failure even when this retry failed validation.
          onBatchCompleted(batchId)
          if TimelineRetryPolicy.canContinueQueue(after: error) {
            self.processNext(index: index + 1, batchIds: batchIds, onBatchCompleted: onBatchCompleted)
          } else {
            self.markRemainingStopped(from: index + 1, batchIds: batchIds)
            self.finishRun()
          }
        }
      }
    )
  }

  private func markRemainingStopped(from index: Int, batchIds: [Int64]) {
    guard index < batchIds.count else { return }
    for i in index..<batchIds.count {
      statuses[batchIds[i]] = .stopped
    }
  }

  private func finishRun() {
    activeBatchId = nil
    isRunning = false
    setManualRetryRunning(false)
    stopDotTimer()
  }

  private func startDotTimerIfNeeded() {
    guard dotTimer == nil else { return }
    dotTick = 0
    dotTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.dotTick = (self.dotTick + 1) % 3
      }
    }
  }

  private func stopDotTimer() {
    dotTimer?.invalidate()
    dotTimer = nil
    dotTick = 0
  }

  private var dots: String {
    String(repeating: ".", count: (dotTick % 3) + 1)
  }

  private func stepLabel(_ step: LLMProcessingStep) -> String {
    switch step {
    case .transcribing:
      return String(localized: "1/2 Transcribing")
    case .generatingCards:
      return String(localized: "2/2 Generating cards")
    }
  }
}
