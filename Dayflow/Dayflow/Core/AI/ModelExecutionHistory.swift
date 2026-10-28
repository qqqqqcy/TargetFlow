import Foundation

/// Metadata only. Never add prompts, output, shell commands, or provider session identifiers here.
struct ModelExecutionRecord: Codable, Identifiable, Equatable {
  enum Outcome: String, Codable { case succeeded, failed }

  let id: UUID
  let provider: String
  let requestedModel: String?
  let reportedModels: [String]
  let requestedReasoning: String?
  let reportedReasoning: String?
  let startedAt: Date
  let finishedAt: Date
  let outcome: Outcome
  /// A machine-readable status (exit code, HTTP status, timeout); never a raw error message.
  let failureCode: String?
}

final class ModelExecutionHistory: @unchecked Sendable {
  static let shared = ModelExecutionHistory()
  static let storageKey = "modelExecutionHistory.v1"
  static let maximumRecords = 50

  // Serialize read/modify/write even when tests or callers use separate history instances.
  private static let storageLock = NSLock()
  private var lock: NSLock { Self.storageLock }
  private let defaults: UserDefaults
  private let limit: Int

  init(defaults: UserDefaults = AppStoragePaths.defaults, limit: Int = maximumRecords) {
    self.defaults = defaults
    self.limit = max(1, min(limit, Self.maximumRecords))
  }

  var records: [ModelExecutionRecord] {
    lock.lock()
    defer { lock.unlock() }
    return load()
  }

  func record(
    provider: String, requestedModel: String?, reportedModels: [String] = [],
    requestedReasoning: String? = nil, reportedReasoning: String? = nil,
    startedAt: Date, finishedAt: Date = Date(), outcome: ModelExecutionRecord.Outcome,
    failureCode: String? = nil
  ) {
    func bounded(_ value: String?) -> String? {
      guard let value, !value.isEmpty else { return nil }
      return String(value.prefix(256))
    }
    let entry = ModelExecutionRecord(
      id: UUID(), provider: bounded(provider) ?? "unknown",
      requestedModel: bounded(requestedModel),
      reportedModels: Array(Set(reportedModels.compactMap { bounded($0) })).sorted().prefix(16).map { $0 },
      requestedReasoning: bounded(requestedReasoning), reportedReasoning: bounded(reportedReasoning),
      startedAt: startedAt, finishedAt: finishedAt, outcome: outcome,
      failureCode: bounded(failureCode))
    lock.lock()
    defer { lock.unlock() }
    var entries = load()
    entries.append(entry)
    entries.sort { $0.finishedAt > $1.finishedAt }
    if let data = try? JSONEncoder().encode(Array(entries.prefix(limit))) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    defaults.removeObject(forKey: Self.storageKey)
  }

  private func load() -> [ModelExecutionRecord] {
    guard let data = defaults.data(forKey: Self.storageKey),
      let entries = try? JSONDecoder().decode([ModelExecutionRecord].self, from: data)
    else { return [] }
    return Array(entries.prefix(limit))
  }
}

/// Shared across stream reader callbacks and the run task; retains metadata only.
final class StreamingExecutionMetadata: @unchecked Sendable {
  private let lock = NSLock()
  private var metadata = CLIReportedExecutionMetadata()
  private var exitCode: Int32 = 0
  private var failed = false

  func observe(line: String) {
    lock.lock()
    defer { lock.unlock() }
    metadata.observe(line: line)
  }

  func resetForRetry() {
    lock.lock()
    defer { lock.unlock() }
    metadata = CLIReportedExecutionMetadata()
    exitCode = 0
    failed = false
  }

  func finish(exitCode: Int32, failed: Bool) {
    lock.lock()
    defer { lock.unlock() }
    self.exitCode = exitCode
    self.failed = failed
  }

  func snapshot() -> (models: [String], reasoning: String?, failed: Bool, failureCode: String?) {
    lock.lock()
    defer { lock.unlock() }
    let isFailure = failed || metadata.reportedFailure || exitCode != 0
    return (metadata.models, metadata.reasoning, isFailure,
      isFailure ? (exitCode != 0 ? "exit \(exitCode)" : "cli_error") : nil)
  }
}

/// Reads only explicit CLI envelope fields, never generated text or tool payloads.
struct CLIReportedExecutionMetadata {
  private(set) var models: [String] = []
  private(set) var reasoning: String?
  private(set) var reportedFailure = false

  mutating func observeJSON(_ value: Any) {
    if let events = value as? [Any] {
      for event in events { observeJSON(event) }
      return
    }
    guard let event = value as? [String: Any], let type = event["type"] as? String else { return }
    let recognized = ["system", "init", "result", "assistant", "thread.started", "turn.started", "turn.completed", "turn.failed", "error"]
    guard recognized.contains(type) else { return }
    // A system event reports configuration only in its init envelope.
    if type == "system", event["subtype"] as? String != "init" { return }
    if let model = event["model"] as? String { add(model) }
    if type == "assistant", let message = event["message"] as? [String: Any],
      let model = message["model"] as? String { add(model) }
    if type == "result", let usage = event["modelUsage"] as? [String: Any] {
      for model in usage.keys.sorted() { add(model) }
    }
    if let effort = event["reasoning_effort"] as? String ?? event["effort"] as? String {
      reasoning = String(effort.prefix(256))
    }
    if type == "error" || type == "turn.failed" || event["is_error"] as? Bool == true {
      reportedFailure = true
    }
  }

  mutating func observe(line: String) {
    guard let data = line.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data) else { return }
    observeJSON(value)
  }

  private mutating func add(_ model: String) {
    let bounded = String(model.prefix(256))
    if !bounded.isEmpty, !models.contains(bounded), models.count < 16 { models.append(bounded) }
  }

  static func parse(_ raw: String) -> Self {
    var metadata = Self()
    // The balanced scanner tolerates login-shell banners and JSON arrays without looking inside
    // JSON string fields (which may contain generated output that resembles metadata).
    for value in ChatCLIProcessRunner().balancedJSONValues(in: raw) {
      metadata.observe(line: value)
    }
    return metadata
  }
}
