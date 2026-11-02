import Foundation
import XCTest
@testable import Dayflow

final class PolicyCorrectionRegressionTests: XCTestCase {
  func testThresholdStartsAtLastInputWithoutExtraSixtySecondWarmup() {
    for threshold in InactivityPreferences.thresholdOptions {
      for cadence in [1, 20, 60] {
        for priorIdle in [0, 1] {
          let frames = stride(from: 0, through: threshold, by: cadence).map { second in
            Screenshot(id: Int64(second + 1), capturedAt: second, filePath: "synthetic",
              fileSize: nil, idleSecondsAtCapture: second + priorIdle, isDeleted: false)
          }
          let pixels: (Screenshot) -> [UInt8]? = { _ in [UInt8](repeating: 40, count: 128) }
          let before = Array(frames.dropLast()) + [Screenshot(id: Int64(threshold),
            capturedAt: threshold - 1, filePath: "synthetic", fileSize: nil,
            idleSecondsAtCapture: threshold - 1 + priorIdle, isDeleted: false)]
          XCTAssertNil(IdleBatchClassifier.assess(before, thresholdSeconds: threshold, pixels: pixels))
          XCTAssertNotNil(IdleBatchClassifier.assess(frames,
            thresholdSeconds: threshold, pixels: pixels), "threshold=\(threshold) cadence=\(cadence)")
          for idle in [Int?(0), nil] {
            var broken = frames
            let middle = broken.count / 2
            let timestamp = broken[middle].capturedAt
            broken[middle] = Screenshot(id: Int64(timestamp + 1), capturedAt: timestamp,
              filePath: "synthetic", fileSize: nil, idleSecondsAtCapture: idle, isDeleted: false)
            XCTAssertNil(IdleBatchClassifier.assess(broken, thresholdSeconds: threshold, pixels: pixels))
          }
        }
      }
    }
  }
  func testExpiredHistoryDoesNotPoisonAnySelectedThreshold() {
    for threshold in InactivityPreferences.thresholdOptions {
      let end = threshold + 600
      let frames = (0...end).map { second in
        Screenshot(id: Int64(second + 1), capturedAt: second, filePath: "synthetic",
          fileSize: nil, idleSecondsAtCapture: second, isDeleted: false,
          isPrivacyRedacted: second == 0)
      }
      var decoded: [Int] = []
      let result = IdleBatchClassifier.assess(
        frames.filter { $0.capturedAt >= end - 60 },
        history: frames.filter { $0.capturedAt < end - 60 }, thresholdSeconds: threshold,
        pixels: { frame in
          decoded.append(frame.capturedAt)
          return frame.capturedAt == 1 ? nil : [UInt8](repeating: 40, count: 128)
        })
      XCTAssertNotNil(result, "threshold \(threshold)")
      XCTAssertEqual(result?.thresholdSeconds, threshold)
      XCTAssertGreaterThanOrEqual(decoded.min() ?? -1,
        end - IdleBatchRules.historyLookbackSeconds(thresholdSeconds: threshold))
      XCTAssertLessThanOrEqual(decoded.count, IdleBatchRules.maximumComparedFrames + 1)
    }
  }

  @MainActor
  func testVisibleIdleAndLegacyAliasUseEvaluatorRatherThanInactivityShortcut() async throws {
    for category in ["Idle", "__unmatched__"] {
      let fixture = try fixture(category: category, evidence: .visible)
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      var calls = 0
      var notifications = 0
      let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage,
        notify: { _, _, _ in notifications += 1; return true },
        generate: { prompt in
          calls += 1
          XCTAssertTrue(prompt.contains("Actual visible support work"))
          return Self.focused
        })
      store.enqueue(cardIDs: [1])
      await store.waitForEvaluations()
      XCTAssertEqual(calls, 1)
      XCTAssertEqual(fixture.storage.saved[1]?.alignment, .focused)
      XCTAssertEqual(notifications, 0)
      XCTAssertEqual(TimelineEventDisplay.reservedCategory(category)?.isIdle, true)
    }
  }

  @MainActor
  func testPrivateSevereAssessmentSurvivesStoreReloadAndReminderIsDeduplicated() async throws {
    let fixture = try fixture(category: "__privacy__", evidence: .privacyRedacted)
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var calls = 0
    var notifications = 0
    func store() -> TargetStore {
      TargetStore(defaults: fixture.defaults, storage: fixture.storage,
        automaticReminders: AutomaticReminderState(isRecording: true),
        notify: { _, _, allowed in
          guard allowed() else { return false }
          notifications += 1
          return true
        }, generate: { prompt in
          calls += 1
          let json = try XCTUnwrap(prompt.components(separatedBy: "Evidence:\n").last)
          let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
          XCTAssertEqual(fields["privacyProtected"], "true")
          XCTAssertEqual(fields["durationMinutes"], "10.0")
          for key in ["title", "summary", "details", "distractionIntervals", "observationsAfterTargetStarted"] {
            XCTAssertEqual(fields[key], "", key)
          }
          return Self.severe
        })
    }
    let first = store()
    first.enqueue(cardIDs: [1])
    await first.waitForEvaluations()
    let restored = store()
    restored.enqueue(cardIDs: [1])
    await restored.waitForEvaluations()
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(notifications, 1)
    XCTAssertEqual(restored.assessments[1]?.alignment, .severe)
    XCTAssertEqual(fixture.storage.saved[1]?.alignment, .severe)
  }

  @MainActor
  func testPrivacyStillHonorsStalenessAndAlertsDisabled() async throws {
    for stale in [false, true] {
      let fixture = try fixture(category: "__privacy__", evidence: .privacyRedacted,
        endOffset: stale ? -3600 : 0)
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      fixture.defaults.set(stale, forKey: TargetPreferences.alertsEnabledKey)
      var calls = 0
      var notifications = 0
      let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage,
        notify: { _, _, _ in notifications += 1; return true },
        generate: { _ in calls += 1; return Self.severe })
      store.enqueue(cardIDs: [1])
      await store.waitForEvaluations()
      XCTAssertEqual(calls, 1)
      XCTAssertEqual(fixture.storage.saved[1]?.alignment, .severe)
      XCTAssertEqual(notifications, 0)
    }
  }

  @MainActor
  private func fixture(category: String, evidence: ActivityEvidenceKind, endOffset: Int = 0) throws
    -> (defaults: UserDefaults, suite: String, storage: PolicyCorrectionMemoryStorage) {
    let suite = "PolicyCorrectionRegressionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: TargetPreferences.alertsEnabledKey)
    let now = Int(Date().timeIntervalSince1970)
    let target = FocusTarget(id: UUID(), text: "Implement login",
      startedAt: Date(timeIntervalSince1970: Double(now - 7200)))
    defaults.set(try JSONEncoder().encode(target), forKey: "target.current")
    let storage = PolicyCorrectionMemoryStorage()
    storage.card = TimelineCardWithTimestamps(id: 1, startTimestamp: "10:00 AM", endTimestamp: "10:10 AM",
      startTs: now + endOffset - 600, endTs: now + endOffset, category: category, subcategory: "",
      title: "Actual visible support work", summary: "SENSITIVE_LEGACY_SUMMARY",
      detailedSummary: "SENSITIVE_LEGACY_DETAILS", day: "2026-10-30", distractions: nil,
      videoSummaryURL: nil, evidenceKind: evidence)
    return (defaults, suite, storage)
  }

  private static let focused = #"{"alignment":"focused","reason":"Supports login","reminder":""}"#
  private static let severe = #"{"alignment":"severe","reason":"Ten minutes without evidenced goal progress","reminder":"Return to login"}"#
}

private final class PolicyCorrectionMemoryStorage: TargetStorage {
  var card: TimelineCardWithTimestamps?
  var saved: [Int64: TargetAssessment] = [:]
  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] {
    guard let card else { return [] }
    return [Observation(id: nil, batchId: 1, startTs: card.startTs, endTs: card.endTs,
      observation: "SENSITIVE_LEGACY_OBSERVATION", metadata: nil, llmModel: nil, createdAt: nil)]
  }
  func fetchTargetAssessments() throws -> [TargetAssessment] { Array(saved.values) }
  func targetCandidateCardIDs(since date: Date) throws -> [Int64] { card.map { [$0.id] } ?? [] }
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? { card?.id == id ? card : nil }
  func saveTargetAssessment(_ assessment: TargetAssessment, card: TimelineCardWithTimestamps) throws -> Bool {
    guard let current = self.card, TargetStore.fingerprint(current) == TargetStore.fingerprint(card) else { return false }
    saved[card.id] = assessment
    return true
  }
}
