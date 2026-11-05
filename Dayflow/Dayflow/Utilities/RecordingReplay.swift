import Combine
import CryptoKit
import Foundation
import GRDB

/// Explicitly opt-in replay of a prepared snapshot. Never starts recording or a catch-up timer.
@MainActor
final class RecordingReplay: ObservableObject {
  static let shared = RecordingReplay()
  nonisolated static var isRequested: Bool {
    ProcessInfo.processInfo.environment["TARGETFLOW_REPLAY_MANIFEST"] != nil
      || Bundle.main.object(forInfoDictionaryKey: "TargetFlowReplayPreview") as? Bool == true
  }

  nonisolated static var isViewOnly: Bool {
    if let value = ProcessInfo.processInfo.environment["TARGETFLOW_REPLAY_VIEW_ONLY"] { return value == "1" }
    return Bundle.main.object(forInfoDictionaryKey: "TargetFlowReplayViewOnly") as? Bool == true
  }

  @Published private(set) var elapsedSeconds: Double = 0
  @Published private(set) var status = "等待回放"
  @Published private(set) var isRunning = false
  @Published private(set) var completedBatches = 0
  @Published private(set) var totalBatches = 0
  @Published private(set) var selectedDate: Date?
  @Published private(set) var reportPath: String?
  @Published private(set) var modelDescription: String?

  private struct Manifest: Codable, Equatable {
    struct Window: Codable, Equatable {
      let label: String
      let startTs: Int
      let endTs: Int
    }
    let version: Int
    let windows: [Window]
    let replayStartTs: Int
    let captureContinuityMode: String?
    let sourceDatabaseSHA256: String?
    let createdAt: String?
  }

  private struct BatchResult: Codable {
    let window: String
    let windowStartTs: Int
    let startTs: Int
    let endTs: Int
    let frameCount: Int
    let redactedCount: Int
    let screenshotIDs: [Int64]
    var batchID: Int64?
    var status: String = "pending"
    var error: String?
    var cardIDs: [Int64] = []
    var startedAt: Date?
    var elapsedSeconds: Double = 0
  }

  private struct ModelSelection: Codable {
    let feature: String
    let provider: String
    let connectionID: UUID
    let modelID: String
    let effort: String?
  }

  private struct ActualModelUsage: Codable {
    let model: String
    let operation: String
    let status: String
    let count: Int
  }

  private struct EvaluationAttempt: Codable {
    let cardID: Int64
    var status: String
    let startedAt: Date
    var elapsedSeconds: Double
    var error: String?
  }

  private struct ManualRetry: Codable {
    let batchID: Int64
    let requestedAt: Date
    let previousStatus: String
    let previousError: String?
  }

  private struct Report: Codable {
    var manualRetries: [ManualRetry]?
    var version = 1
    var manifestSHA256: String?
    var manifest: Manifest?
    var startedAt = Date()
    var updatedAt = Date()
    var finishedAt: Date?
    var stoppedError: String?
    var evaluations: [EvaluationAttempt]?
    var status = "准备回放"
    var elapsedSeconds: Double = 0
    var targetEvaluationSeconds: Double = 0
    var targetDuration: Double = 0
    var maxGap: Double = 0
    var aiConfigurationVersion: Int?
    var models: [ModelSelection] = []
    var actualModelUsage: [ActualModelUsage]?
    var limitations: [String] = []
    var batches: [BatchResult] = []
    var activeCards: [TimelineCard] = []
    var assessments: [TargetAssessment] = []
    var assessmentCounts: [String: Int] = [:]
    var failures: [String] = []
  }

  private var report = Report()
  private var directory: URL?
  private var hasStarted = false
  private var reportFileName = "report.json"
  private var evaluationIDs = Set<Int64>()

  private init() {}

  func startIfRequested() {
    guard Self.isRequested, !hasStarted else { return }
    hasStarted = true
    guard AppStoragePaths.isUIPreview, !AppStoragePaths.isTesting,
      let root = AppStoragePaths.uiPreviewDataDirectory
    else {
      status = "回放仅能在独立的界面预览应用中运行，请设置隔离数据目录。"
      return
    }
    directory = root.standardizedFileURL.resolvingSymlinksInPath()
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("report.json").path) {
      reportFileName = "replay-error.json"
    }
    isRunning = true
    Task {
      defer { isRunning = false }
      do {
        try await run()
      } catch {
        status = "回放停止：\(error.localizedDescription)"
        report.status = status
        report.stoppedError = error.localizedDescription
        report.finishedAt = nil
        guard !Self.isViewOnly else { return }
        do { try persist() } catch {
          status += "；报告写入失败：\(error.localizedDescription)"
        }
      }
    }
  }

  private func run() async throws {
    guard let manifestURL = AppStoragePaths.replayManifestURL,
      contains(manifestURL)
    else {
      throw failure("TARGETFLOW_REPLAY_MANIFEST 必须为隔离数据目录内的绝对路径，请检查路径及符号链接。")
    }
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    report.limitations = limitations(for: manifest)
    let orderedWindows = manifest.windows.sorted { $0.startTs < $1.startTs }
    guard manifest.version == 1, !orderedWindows.isEmpty,
      manifest.replayStartTs > 0,
      orderedWindows.allSatisfy({ $0.startTs > 0 && $0.endTs > $0.startTs }),
      manifest.replayStartTs <= orderedWindows[0].startTs
    else { throw failure("清单须使用 version:1、非空有效时间窗口，且 replayStartTs 不晚于首个窗口。") }
    for pair in zip(orderedWindows, orderedWindows.dropFirst()) {
      guard pair.0.endTs <= pair.1.startTs else {
        throw failure("回放窗口不可重叠，请调整 startTs/endTs。")
      }
    }
    selectedDate = Date(timeIntervalSince1970: Double(orderedWindows[0].startTs))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let reportURL = try outputURL("report.json")
    let requestedRetryIDs = Set((ProcessInfo.processInfo.environment["TARGETFLOW_REPLAY_RETRY_BATCH_IDS"] ?? "")
      .split(separator: ",").compactMap { token -> Int64? in
        guard token.allSatisfy({ $0 >= "0" && $0 <= "9" }), let id = Int64(token), id > 0 else { return nil }
        return id
      })
    var retryIDs = Set<Int64>()
    if FileManager.default.fileExists(atPath: reportURL.path) {
      let saved = try JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL))
      guard saved.manifestSHA256 == digest else {
        throw failure("已有报告属于其他清单，请使用新的隔离快照目录。")
      }
      report = saved
      report.limitations = limitations(for: manifest)
      reportFileName = "report.json"
      let usedRetries = Set((saved.manualRetries ?? []).map(\.batchID))
      retryIDs = Set(saved.batches.compactMap { item -> Int64? in
        guard let id = item.batchID, requestedRetryIDs.contains(id), !usedRetries.contains(id),
          ["failed", "processing", "interrupted"].contains(item.status) else { return nil }
        return id
      })
      if Self.isViewOnly || (saved.finishedAt != nil && retryIDs.isEmpty) {
        status = Self.isViewOnly && saved.finishedAt == nil ? "结果快照：\(saved.status)" : saved.status
        completedBatches = saved.batches.filter {
          ["completed", "failed", "interrupted"].contains($0.status)
        }.count
        totalBatches = saved.batches.filter { $0.status != "raw-only" }.count
        elapsedSeconds = saved.elapsedSeconds
        reportPath = reportURL.path
        if Self.isViewOnly {
          try refreshActualModelUsage()
        } else {
          try persist()
        }
        return
      }
      // Persisted in-flight work is reviewable, never silently retried after a crash.
      for index in report.batches.indices where report.batches[index].status == "processing" {
        let item = report.batches[index]
        if let id = item.batchID,
          let savedBatch = StorageManager.shared.allBatches().first(where: { $0.id == id }),
          savedBatch.start == item.startTs, savedBatch.end == item.endTs,
          ["completed", "analyzed"].contains(savedBatch.status),
          Set(StorageManager.shared.screenshotsForBatch(id).map(\.id)) == Set(item.screenshotIDs)
        {
          report.batches[index].status = "completed"
          report.batches[index].cardIDs = cards(from: item.startTs, to: item.endTs).compactMap(\.recordId)
          continue
        }
        if let id = item.batchID, retryIDs.contains(id) { continue }
        report.batches[index].status = "interrupted"
        report.batches[index].error = "上次回放中断；未自动重试，请检查数据库中的真实调用记录。"
        report.failures.append("批次 \(report.batches[index].batchID ?? 0) 上次回放中断")
      }
      for index in report.batches.indices {
        let item = report.batches[index]
        guard let id = item.batchID, retryIDs.contains(id), item.status != "completed" else { continue }
        let batches = StorageManager.shared.allBatches()
        guard report.batches.filter({ $0.batchID == id }).count == 1,
          let source = batches.first(where: { $0.id == id }),
          source.start == item.startTs, source.end == item.endTs,
          Set(StorageManager.shared.screenshotsForBatch(id).map(\.id)) == Set(item.screenshotIDs),
          batches.filter({ $0.id != id }).allSatisfy({
            Set(StorageManager.shared.screenshotsForBatch($0.id).map(\.id)).isDisjoint(with: item.screenshotIDs)
          })
        else { throw failure("重试批次 \(id) 的来源、时间或截图不匹配，请检查隔离数据库。") }
        if report.manualRetries == nil { report.manualRetries = [] }
        report.manualRetries!.append(ManualRetry(batchID: id, requestedAt: Date(),
          previousStatus: item.status, previousError: item.error))
        report.batches[index].status = "pending"
        report.batches[index].error = nil
        report.finishedAt = nil
        try persist()
      }
    } else {
      guard !Self.isViewOnly else { throw failure("结果预览需要已有的 report.json，不会发起新的模型分析。") }
      reportFileName = "report.json"
      report.manifestSHA256 = digest
      report.manifest = manifest
    }

    let configuration = try AIConfigurationStore.shared.load()
    try configuration.validate()
    let service = LLMService(loadConfiguration: { configuration })
    report.aiConfigurationVersion = configuration.schemaVersion
    report.models = try [AIFeature.timeline, .targetEvaluation].flatMap { feature in
      let assignments = configuration.assignments(for: feature)
      guard !assignments.isEmpty else {
        throw failure("请在隔离应用的 AI 设置中配置 \(feature.displayName) 模型。")
      }
      return try assignments.map { assignment in
        let selection = try configuration.selection(for: assignment)
        return ModelSelection(
          feature: feature.rawValue, provider: selection.connection.kind.rawValue,
          connectionID: selection.connection.id, modelID: selection.modelID, effort: selection.effort)
      }
    }
    let store = StorageManager.shared
    // Validate media even on resume before handing any saved batch to production analysis.
    for window in orderedWindows {
      for frame in store.fetchScreenshotsInTimeRange(startTs: window.startTs, endTs: window.endTs)
        where frame.capturedAt < window.endTs
      {
        let mediaURL = frame.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(mediaURL) else {
          throw failure("截图 \(frame.id) 的媒体真实路径不在隔离目录内（可能存在符号链接逃逸），请重新准备快照。")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mediaURL.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        else {
          throw failure("截图 \(frame.id) 的隔离媒体缺失或不是文件，请重新复制所选媒体。")
        }
      }
    }
    let config = service.batchingConfig
    if report.batches.isEmpty {
      report.targetDuration = config.targetDuration
      report.maxGap = config.maxGap
      for window in orderedWindows {
        let frames = store.fetchScreenshotsInTimeRange(startTs: window.startTs, endTs: window.endTs)
          .filter { $0.capturedAt < window.endTs }
        var batches = ScreenshotBatcher.batches(
          from: frames, targetDuration: config.targetDuration, maxGap: config.maxGap)
        let assigned = Set(batches.flatMap { $0.screenshots.map(\.id) })
        let trailing = frames.filter { !assigned.contains($0.id) }
        if let first = trailing.first, let last = trailing.last {
          batches.append(ScreenshotBatch(screenshots: trailing, start: first.capturedAt, end: last.capturedAt))
        }
        for batch in batches {
          var result = BatchResult(
            window: window.label, windowStartTs: window.startTs,
            startTs: batch.start, endTs: batch.end, frameCount: batch.screenshots.count,
            redactedCount: batch.screenshots.filter(\.isPrivacyRedacted).count,
            screenshotIDs: batch.screenshots.map(\.id))
          if batch.duration < ScreenshotBatcher.minimumDuration { result.status = "raw-only" }
          report.batches.append(result)
        }
        if frames.isEmpty { report.failures.append("窗口「\(window.label)」没有可用截图。") }
      }
    } else {
      guard report.targetDuration == config.targetDuration, report.maxGap == config.maxGap else {
        throw failure("批处理间隔或最大间隙已变化，请恢复原设置或使用新的快照目录。")
      }
    }
    report.stoppedError = nil
    try persist()

    for index in report.batches.indices where report.batches[index].status == "pending" {
      let item = report.batches[index]
      selectedDate = Date(timeIntervalSince1970: Double(item.startTs))
      let isManualRetry = item.batchID.map { retryIDs.contains($0) } ?? false
      let existing = store.allBatches().filter { $0.start == item.startTs && $0.end == item.endTs }
        .first { (!isManualRetry || $0.id == item.batchID)
          && Set(store.screenshotsForBatch($0.id).map(\.id)) == Set(item.screenshotIDs) }
      if let existing, !isManualRetry {
        report.batches[index].batchID = existing.id
        if ["completed", "analyzed"].contains(existing.status) {
          report.batches[index].status = "completed"
          report.batches[index].cardIDs = cards(from: item.startTs, to: item.endTs).compactMap(\.recordId)
          try persist()
          continue
        }
        if existing.status == "failed" {
          let reason = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT reason FROM analysis_batches WHERE id = ?", arguments: [existing.id])
          } ?? "源回放的分析失败，详情见原始调用记录。"
          report.batches[index].status = "failed"
          report.batches[index].error = reason
          report.batches[index].cardIDs = cards(from: item.startTs, to: item.endTs).compactMap(\.recordId)
          let message = "批次 \(existing.id)：\(reason)"
          if !report.failures.contains(message) { report.failures.append(message) }
          try persist()
          continue
        }
        // A saved batch without a terminal report may already have made a model call.
        report.batches[index].status = "interrupted"
        report.batches[index].error = "数据库已有未完成的同源批次（\(existing.status)），未自动重复提交。"
        report.failures.append("批次 \(existing.id) 已存在但未完成")
        try persist()
        continue
      }
      let id: Int64
      if isManualRetry {
        guard let existing else { throw failure("重试批次已不存在或截图已变化。") }
        id = existing.id
      } else {
        let assignedIDs = Set(store.allBatches().flatMap { store.screenshotsForBatch($0.id).map(\.id) })
        guard assignedIDs.isDisjoint(with: item.screenshotIDs) else {
          throw failure("窗口「\(item.window)」存在已分配至其他批次的截图，请重新准备隔离快照。")
        }
        guard let savedID = store.saveBatchWithScreenshots(
          startTs: item.startTs, endTs: item.endTs, screenshotIds: item.screenshotIDs)
        else { throw failure("无法保存窗口「\(item.window)」的批次，请检查隔离数据库。") }
        id = savedID
      }
      report.batches[index].batchID = id
      report.batches[index].status = "processing"
      report.batches[index].startedAt = Date()
      status = "正在分析第 \(completedBatches + 1)/\(totalBatches) 段：\(item.window)"
      try persist()
      // Preserve the production default: historical frames lack reliable negative privacy provenance.
      let manager = AnalysisManager(
        store: store, llmService: service,
        evaluate: { [weak self] ids in self?.evaluationIDs.formUnion(ids) })
      // Queue ordering guarantees this flag takes effect before reprocessBatch.
      manager.setManualRetryRunning(true)
      let started = Date()
      let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
        manager.reprocessBatch(id, stepHandler: { _ in }) { result in
          continuation.resume(returning: result)
        }
      }
      // AnalysisManager posts evaluation on the main actor separately from completion.
      await Task.yield()
      report.batches[index].elapsedSeconds = Date().timeIntervalSince(started)
      report.batches[index].cardIDs = cards(from: item.startTs, to: item.endTs).compactMap(\.recordId)
      switch outcome {
      case .success:
        report.batches[index].status = "completed"
      case .failure(let error):
        report.batches[index].status = "failed"
        report.batches[index].error = error.localizedDescription
        report.failures.append("批次 \(id)：\(error.localizedDescription)")
      }
      try persist()
    }

    // Query active cards after every timeline rewrite has settled, including resumed batches.
    report.activeCards = activeCards(manifest)
    evaluationIDs.formUnion(report.activeCards.compactMap(\.recordId))
    let activeIDs = Set(report.activeCards.compactMap(\.recordId))
    let targets = TargetStore(
      allowReplayEvaluation: true,
      automaticReminders: AutomaticReminderState(isRecording: false),
      notify: { _, _, _ in false },
      generate: { prompt in try await service.generateTargetEvaluation(prompt: prompt) })
    if targets.target == nil {
      report.failures.append("隔离偏好中没有启用的目标，未进行目标评估；请检查快照目标及回放起始时间。")
    }
    let evaluationStart = Date()
    let previousEvaluationSeconds = report.targetEvaluationSeconds
    status = "时间线分析完成，正在评估最终目标卡片"
    // An in-flight attempt may already have incurred a paid call. Never enqueue it again.
    if report.evaluations != nil {
      for index in report.evaluations!.indices where report.evaluations![index].status == "processing" {
        report.evaluations![index].status = "interrupted"
        report.evaluations![index].error = "上次目标评估中断；未自动重复提交。"
      }
    }
    var committed: [TargetAssessment] = []
    try persist()
    for id in evaluationIDs.intersection(activeIDs).sorted() {
      guard let target = targets.target,
        let card = store.fetchTimelineCard(byId: id), card.category != "System",
        TargetEvaluationPolicy.isEligible(
          endTime: Date(timeIntervalSince1970: Double(card.endTs)), target: target)
      else { continue }
      let fingerprint = TargetStore.fingerprint(card)
      let existingIndex = report.evaluations?.firstIndex { $0.cardID == id }
      if let assessment = targets.assessments[id], assessment.targetID == target.id,
        assessment.fingerprint == fingerprint
      {
        committed.append(assessment)
        if let index = existingIndex {
          report.evaluations![index].status = "completed"
          report.evaluations![index].error = nil
        } else {
          if report.evaluations == nil { report.evaluations = [] }
          report.evaluations!.append(EvaluationAttempt(
            cardID: id, status: "completed", startedAt: Date(), elapsedSeconds: 0))
        }
      } else if let index = existingIndex {
        // Terminal failures and unresolved interrupted attempts remain part of the audit.
        if report.evaluations![index].status == "interrupted" {
          let message = "目标卡片 \(id)：\(report.evaluations![index].error ?? "上次目标评估中断")"
          if !report.failures.contains(message) { report.failures.append(message) }
        }
      } else {
        let started = Date()
        if report.evaluations == nil { report.evaluations = [] }
        report.evaluations!.append(EvaluationAttempt(
          cardID: id, status: "processing", startedAt: started, elapsedSeconds: 0))
        let index = report.evaluations!.count - 1
        try persist()
        targets.enqueue(cardIDs: [id])
        await targets.waitForEvaluations()
        report.evaluations![index].elapsedSeconds = Date().timeIntervalSince(started)
        if let assessment = targets.assessments[id], assessment.targetID == target.id,
          assessment.fingerprint == fingerprint
        {
          report.evaluations![index].status = "completed"
          committed.append(assessment)
        } else {
          let error = targets.lastError ?? "目标评估未提交匹配的结果。"
          report.evaluations![index].status = "failed"
          report.evaluations![index].error = error
          report.failures.append("目标卡片 \(id)：\(error)")
        }
      }
      report.assessments = committed.sorted { $0.cardID < $1.cardID }
      report.assessmentCounts = Dictionary(grouping: report.assessments, by: { $0.alignment.rawValue })
        .mapValues(\.count)
      TargetStore.shared.refreshAssessments()
      report.targetEvaluationSeconds = previousEvaluationSeconds + Date().timeIntervalSince(evaluationStart)
      try persist()
    }
    report.assessments = committed.sorted { $0.cardID < $1.cardID }
    report.assessmentCounts = Dictionary(grouping: report.assessments, by: { $0.alignment.rawValue })
      .mapValues(\.count)
    report.finishedAt = Date()
    status = report.failures.isEmpty ? "回放完成，可刷新查看真实模型结果" : "回放完成，部分失败可在报告中查看"
    try persist()
  }

  private func limitations(for manifest: Manifest) -> [String] {
    let mode: String
    if manifest.captureContinuityMode == "timestamp-and-frame-index" {
      mode = "连续虚拟录制模拟：将保存的图像输入连续会话，由隔离回放账本按 replayStartTs 初始化；仍使用生产时间戳节奏、间隙、帧索引及日界检查。Continuous virtual recording simulation: saved images are fed into a continuous session initialized at replayStartTs; production timestamp cadence, gap, frame-index and day-boundary checks still apply."
    } else {
      mode = "历史保守模式：未知的历史停止证据保持 nil，提前关闭的媒体片段可能导致保守拆分；文件轮换本身不证明连续采集。Conservative historical mode: unknown historical stop evidence remains nil; early-closed segments may split conservatively, and rotation alone does not prove continuity."
    }
    return [
      mode,
      "保留生产隐私证据起点（当前进程时间 +1 秒）；历史截图的非隐私来源未知，不使用窗口起点启用空闲快捷判断。The production privacy evidence cutoff (current process time +1 second) is preserved; historical frames have unknown negative privacy provenance and do not enable the idle shortcut via the window start.",
      "历史会话停止记录未持久化，无法重建短于采集节奏的暂停。Historical session stops were not persisted; pauses shorter than the capture cadence cannot be reconstructed.",
      "不足 60 秒的片段仅保留原始记录，不提交模型。Spans shorter than 60 seconds remain raw-only and are not submitted to a model.",
    ]
  }

  private func activeCards(_ manifest: Manifest) -> [TimelineCard] {
    var seen = Set<Int64>()
    return manifest.windows.flatMap { cards(from: $0.startTs, to: $0.endTs) }
      .filter { card in
        guard let id = card.recordId else { return false }
        return seen.insert(id).inserted
      }.sorted { ($0.startTs ?? 0) < ($1.startTs ?? 0) }
  }

  private func cards(from start: Int, to end: Int) -> [TimelineCard] {
    StorageManager.shared.fetchTimelineCardsByTimeRange(
      from: Date(timeIntervalSince1970: Double(start)),
      to: Date(timeIntervalSince1970: Double(end)))
  }

  private func contains(_ url: URL) -> Bool {
    guard let directory else { return false }
    return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/")
  }

  private func outputURL(_ name: String) throws -> URL {
    guard let directory else { throw failure("缺少隔离数据目录。") }
    let url = directory.appendingPathComponent(name)
    guard contains(url) else { throw failure("\(name) 指向隔离目录之外，请移除该符号链接。") }
    return url
  }

  private func refreshActualModelUsage() throws {
    report.actualModelUsage = try StorageManager.shared.db.read { db in
      try Row.fetchAll(db, sql: """
        SELECT model, operation, status, COUNT(*) AS count
        FROM llm_calls
        GROUP BY model, operation, status
        ORDER BY model, operation, status
        """).map { row in
          ActualModelUsage(
            model: (row["model"] as String?) ?? "(unrecorded)",
            operation: row["operation"], status: row["status"], count: row["count"])
        }
    }
    let usage = report.actualModelUsage ?? []
    let timelineModels = Set(usage.filter {
      $0.operation == "generate_timeline" && $0.model != "(unrecorded)" && !$0.model.isEmpty
    }.map(\.model)).sorted()
    modelDescription = timelineModels.isEmpty
      ? report.models.first(where: { $0.feature == AIFeature.timeline.rawValue })?.modelID
      : timelineModels.joined(separator: ", ")

    let configuredModels = Set(report.models.map(\.modelID))
    let unexpectedModels = Set(usage.map(\.model)).subtracting(configuredModels).sorted()
    let notePrefix = "Actual model usage differs from configured routes: "
    if !unexpectedModels.isEmpty {
      let note = notePrefix + "logged [\(unexpectedModels.joined(separator: ", "))]; "
        + "configured [\(configuredModels.sorted().joined(separator: ", "))]. "
        + "See actualModelUsage for recorded operations, statuses and counts."
      if let index = report.limitations.firstIndex(where: { $0.hasPrefix(notePrefix) }) {
        report.limitations[index] = note
      } else {
        report.limitations.append(note)
      }
    }
  }

  private func persist() throws {
    try refreshActualModelUsage()
    report.updatedAt = Date()
    report.elapsedSeconds = (report.finishedAt ?? report.updatedAt).timeIntervalSince(report.startedAt)
    report.status = status
    elapsedSeconds = report.elapsedSeconds
    completedBatches = report.batches.filter {
      ["completed", "failed", "interrupted"].contains($0.status)
    }.count
    totalBatches = report.batches.filter { $0.status != "raw-only" }.count
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    // Keep the report and progress independently readable throughout a long model call.
    let data = try encoder.encode(report)
    let reportURL = try outputURL(reportFileName)
    try data.write(to: reportURL, options: .atomic)
    reportPath = reportURL.path
    try data.write(to: outputURL("progress.json"), options: .atomic)
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "RecordingReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
