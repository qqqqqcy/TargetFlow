import Combine
import CryptoKit
import Foundation

@MainActor
final class TargetStore: ObservableObject {
  static let shared = TargetStore()

  @Published private(set) var target: FocusTarget?
  @Published private(set) var assessments: [Int64: TargetAssessment] = [:]
  @Published private(set) var isEvaluating = false
  @Published private(set) var remainingEvaluationCount = 0
  @Published private(set) var isSendingReminder = false
  @Published private(set) var lastError: String?

  private let defaults: UserDefaults
  private let storage: any TargetStorage
  private let allowReplayEvaluation: Bool
  private var pending: [Int64] = []
  private var reminderGenerations: [Int64: UUID] = [:]
  private let automaticReminders: AutomaticReminderState
  private var isProcessingCard = false
  private var worker: Task<Void, Never>?
  private static let targetKey = "target.current"
  private let notify: (String, String, @escaping () -> Bool) async throws -> Bool
  private static let notifiedEndKey = "target.lastNotifiedEnd"

  init(
    defaults: UserDefaults = AppStoragePaths.defaults,
    storage: any TargetStorage = StorageManager.shared,
    allowReplayEvaluation: Bool = false,
    automaticReminders: AutomaticReminderState? = nil,
    notify: @escaping (String, String, @escaping () -> Bool) async throws -> Bool = {
      try await NotificationService.shared.notifyTargetDeviation(
        identifier: $0, body: $1, shouldSend: $2)
    },
    // Retained for source compatibility with injected clients. Alignment is local;
    // this closure is deliberately never invoked.
    generate: @escaping (String) async throws -> String = { _ in
      throw TargetEvaluationError.invalidResponse
    }
  ) {
    self.defaults = defaults
    self.storage = storage
    self.allowReplayEvaluation = allowReplayEvaluation && AppStoragePaths.replayManifestURL != nil
    self.notify = notify
    self.automaticReminders = automaticReminders ?? .shared
    if let data = defaults.data(forKey: Self.targetKey) {
      target = try? JSONDecoder().decode(FocusTarget.self, from: data)
    }
    refreshAssessments()
  }

  func synchronize(events: [TimelineCategory]) {
    let active = events.filter { $0.isCurrentTarget && $0.isEnabled }.map {
      FocusTargetEvent(id: $0.id, name: $0.name, details: $0.details)
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    guard !active.isEmpty else {
      clearTarget()
      return
    }
    // Reordering or recoloring an event does not restart the active goal session.
    guard target?.events != active else { return }
    NotchNotificationController.shared.dismissImmediately()
    let legacyStart = target.flatMap { old in
      old.events == nil && active.count == 1 && active[0].id == old.id ? old.startedAt : nil
    }
    let text = active.map { $0.details.isEmpty ? $0.name : "\($0.name)：\($0.details)" }
      .joined(separator: "\n")
    let value = FocusTarget(
      id: UUID(), text: text, startedAt: legacyStart ?? Date(), events: active)
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: Self.targetKey)
    defaults.removeObject(forKey: Self.notifiedEndKey)
    target = value
    pending.removeAll()
    reminderGenerations.removeAll()
    updateRemainingCount()
    lastError = nil
    refreshAssessments()
    retryPendingEvaluations()
  }

  private func clearTarget() {
    NotchNotificationController.shared.dismissImmediately()
    target = nil
    defaults.removeObject(forKey: Self.targetKey)
    pending.removeAll()
    reminderGenerations.removeAll()
    updateRemainingCount()
    lastError = nil
  }

  func retryPendingEvaluations() {
    guard let target else { return }
    do {
      lastError = nil
      enqueue(cardIDs: try storage.targetCandidateCardIDs(since: target.startedAt))
    } catch {
      lastError = String(localized: "Could not load cards awaiting evaluation: \(error.localizedDescription)")
    }
  }

  func enqueue(cardIDs: [Int64]) {
    if allowReplayEvaluation { lastError = nil }
    refreshAssessments()
    guard !AppStoragePaths.isUIPreview || allowReplayEvaluation else { return }
    guard target != nil else { return }
    for id in cardIDs where !pending.contains(id) {
      pending.append(id)
      reminderGenerations[id] = automaticReminders.generation
    }
    updateRemainingCount()
    guard worker == nil, !pending.isEmpty else { return }
    worker = Task { await drainQueue() }
  }

  func waitForEvaluations() async {
    await worker?.value
  }

  func assessment(for cardID: Int64) -> TargetAssessment? {
    guard let assessment = assessments[cardID],
      let card = storage.fetchTimelineCard(byId: cardID),
      assessment.fingerprint == Self.fingerprint(card) else { return nil }
    return assessment
  }

  func refreshAssessments() {
    assessments = [:]
    do {
      var refreshed: [Int64: TargetAssessment] = [:]
      for previous in try storage.fetchTargetAssessments() {
        guard let card = storage.fetchTimelineCard(byId: previous.cardID),
          card.category != "System" else { continue }
        // Never reinterpret old sessions using today's goals. Legacy records retain
        // the displayed goal text; split only the format used by synchronize().
        let events = previous.targetEvents ?? TargetEvaluationPolicy.legacyEvents(
          text: previous.targetText, id: previous.targetID)
        guard !events.isEmpty else { continue }
        let response = TargetEvaluationPolicy.evaluate(category: card.category, events: events)
        let updated = TargetAssessment(
          cardID: previous.cardID, targetID: previous.targetID, targetText: previous.targetText,
          cardTitle: card.title, fingerprint: Self.fingerprint(card),
          startTime: previous.startTime, endTime: Date(timeIntervalSince1970: Double(card.endTs)),
          alignment: response.alignment, reason: response.reason, reminder: response.reminder,
          targetEvents: events)
        // Hide stale judgments immediately, even if persistence fails.
        if previous != updated {
          guard try storage.saveTargetAssessment(updated, card: card) else { continue }
        }
        refreshed[updated.cardID] = updated
      }
      assessments = refreshed
    } catch {
      lastError = String(localized: "Could not load goal assessments: \(error.localizedDescription)")
    }
  }

  private func updateRemainingCount() {
    remainingEvaluationCount = pending.count + (isProcessingCard ? 1 : 0)
  }

  private func drainQueue() async {
    isEvaluating = true
    defer {
      isProcessingCard = false
      updateRemainingCount()
      isEvaluating = false
      worker = nil
    }
    while !pending.isEmpty {
      let id = pending.removeFirst()
      let reminderGeneration = reminderGenerations.removeValue(forKey: id)
      defer {
        isProcessingCard = false
        updateRemainingCount()
      }
      guard let snapshot = target,
        let card = storage.fetchTimelineCard(byId: id), card.category != "System",
        TargetEvaluationPolicy.isEligible(
          endTime: Date(timeIntervalSince1970: Double(card.endTs)), target: snapshot)
      else { continue }
      let fingerprint = Self.fingerprint(card)
      isProcessingCard = true
      updateRemainingCount()
      do {
        if let previous = assessments[id], previous.targetID == snapshot.id,
          previous.fingerprint == fingerprint
        {
          try await sendReminderIfNeeded(previous, generation: reminderGeneration)
          continue
        }
        let evaluationStart = max(
          snapshot.startedAt, Date(timeIntervalSince1970: Double(card.startTs)))
        let response = TargetEvaluationPolicy.evaluate(
          category: card.category,
          events: snapshot.evaluationEvents)
        guard target?.id == snapshot.id else { continue }
        let assessment = TargetAssessment(
          cardID: id, targetID: snapshot.id, targetText: snapshot.text,
          cardTitle: card.title, fingerprint: fingerprint,
          startTime: evaluationStart,
          endTime: Date(timeIntervalSince1970: Double(card.endTs)),
          alignment: response.alignment, reason: response.reason, reminder: response.reminder,
          targetEvents: snapshot.evaluationEvents)
        guard try storage.saveTargetAssessment(assessment, card: card) else { continue }
        assessments[id] = assessment
        try await sendReminderIfNeeded(assessment, generation: reminderGeneration)
      } catch {
        guard target?.id == snapshot.id else { continue }
        lastError = String(localized: "Goal evaluation or reminder failed. Try again: \(error.localizedDescription)")
      }
    }
  }

  private func sendReminderIfNeeded(_ assessment: TargetAssessment, generation: UUID?) async throws {
    guard let generation, canNotify(assessment, generation: generation) else { return }
    isSendingReminder = true
    defer { isSendingReminder = false }
    let sent = try await notify(
      "\(assessment.targetID.uuidString).\(assessment.cardID).\(Int(assessment.endTime.timeIntervalSince1970))",
      assessment.reminder, { self.canNotify(assessment, generation: generation) })
    if sent, canNotify(assessment, generation: generation) {
      defaults.set(assessment.endTime, forKey: Self.notifiedEndKey)
    }
  }

  private func canNotify(_ assessment: TargetAssessment, generation: UUID) -> Bool {
    guard automaticReminders.allows(generation, eventEnd: assessment.endTime),
      target?.id == assessment.targetID,
      TargetPreferences.alertsEnabled(defaults: defaults),
      let card = storage.fetchTimelineCard(byId: assessment.cardID),
      Self.fingerprint(card) == assessment.fingerprint
    else { return false }
    if let end = defaults.object(forKey: Self.notifiedEndKey) as? Date,
      assessment.endTime <= end
    {
      return false
    }
    return TargetEvaluationPolicy.shouldNotify(
      alignment: assessment.alignment, endTime: assessment.endTime, now: Date())
  }

  nonisolated static func hasUnavailableEvidence(_ card: TimelineCardWithTimestamps) -> Bool {
    card.evidenceKind == .unknown && !isPrivacyProtected(card)
  }

  nonisolated static func isPrivacyProtected(_ card: TimelineCardWithTimestamps) -> Bool {
    card.evidenceKind == .privacyRedacted || card.category == TimelineEventDisplay.privacy
  }

  nonisolated static func distractionJSON(_ distractions: [Distraction]?) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let semanticFields = (distractions ?? []).map {
      ["start": $0.startTime, "end": $0.endTime, "title": $0.title, "summary": $0.summary]
    }
    return String(decoding: (try? encoder.encode(semanticFields)) ?? Data(), as: UTF8.self)
  }

  nonisolated static func fingerprint(_ card: TimelineCardWithTimestamps) -> String {
    let parts = [
      "target-evaluation-v6-event-membership", String(card.startTs), String(card.endTs), card.category, card.title,
      card.summary, card.detailedSummary, card.evidenceKind?.rawValue ?? "legacy",
      distractionJSON(card.distractions),
    ]
    let data = (try? JSONEncoder().encode(parts)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

}
