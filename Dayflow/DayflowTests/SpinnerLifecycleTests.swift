import XCTest
@testable import Dayflow

final class SpinnerLifecycleTests: XCTestCase {
  @MainActor
  func testCachedStartupAndRepeatedRetryReuseAssessmentsAndFinishQueue() async {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let first = fixture.store()
    first.retryPendingEvaluations()
    await first.waitForEvaluations()
    let restored = fixture.store()
    for _ in 0..<10 { restored.retryPendingEvaluations() }
    XCTAssertEqual(restored.remainingEvaluationCount, 1)
    await restored.waitForEvaluations()
    XCTAssertEqual(fixture.storage.saveCount, 1)
    XCTAssertEqual(restored.remainingEvaluationCount, 0)
    XCTAssertFalse(restored.isEvaluating)
  }

  @MainActor
  func testLocalBackfillDrainsAllQueuedCardsWithoutModelWait() async {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    fixture.storage.cards[2] = Fixture.card(id: 2)
    let store = fixture.store()
    store.retryPendingEvaluations()
    XCTAssertEqual(store.remainingEvaluationCount, 2)
    fixture.storage.cards[3] = Fixture.card(id: 3)
    store.enqueue(cardIDs: [3, 3])
    XCTAssertEqual(store.remainingEvaluationCount, 3)
    await store.waitForEvaluations()
    XCTAssertEqual(store.assessments.count, 3)
    XCTAssertFalse(store.isEvaluating)
    XCTAssertEqual(store.remainingEvaluationCount, 0)
  }

  @MainActor
  func testDisablingGoalsBeforeWorkerRunsClearsQueuedWork() async {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = fixture.store()
    store.retryPendingEvaluations()
    store.synchronize(events: [])
    await store.waitForEvaluations()
    XCTAssertTrue(store.assessments.isEmpty)
    XCTAssertFalse(store.isEvaluating)
    XCTAssertEqual(store.remainingEvaluationCount, 0)
  }

  @MainActor
  func testOldPolicyFingerprintIsRecomputedLocallyBeforeDisplay() async {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let card = fixture.storage.cards[1]!
    fixture.storage.assessments[1] = TargetAssessment(
      cardID: 1, targetID: fixture.target.id, targetText: fixture.target.text,
      cardTitle: card.title, fingerprint: "previous-policy-fingerprint",
      startTime: Date(timeIntervalSince1970: Double(card.startTs)),
      endTime: Date(timeIntervalSince1970: Double(card.endTs)),
      alignment: .focused, reason: "Old decision", reminder: "")
    let store = fixture.store()
    XCTAssertEqual(store.assessments[1]?.alignment, .severe)
    XCTAssertEqual(store.assessments[1]?.fingerprint, TargetStore.fingerprint(card))
    store.retryPendingEvaluations()
    await store.waitForEvaluations()
    XCTAssertFalse(store.isEvaluating)
  }

  @MainActor
  func testCachedReminderRetryIsVisibleAndNeverCallsModel() async {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    fixture.defaults.set(true, forKey: TargetPreferences.alertsEnabledKey)
    let gate = Gate()
    var notifications = 0
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage,
      automaticReminders: AutomaticReminderState(isRecording: true),
      notify: { _, _, allowed in
        notifications += 1
        if notifications == 1 { throw TestError.notification }
        let result = await gate.value()
        return result == "sent" && allowed()
      }, generate: { _ in XCTFail("No model evaluation"); return "invalid" })
    store.retryPendingEvaluations()
    await store.waitForEvaluations()
    XCTAssertNotNil(store.lastError)
    XCTAssertFalse(store.isSendingReminder)
    store.retryPendingEvaluations()
    await fulfillment(of: [gate.started], timeout: 2)
    XCTAssertTrue(store.isEvaluating)
    XCTAssertTrue(store.isSendingReminder)
    XCTAssertEqual(store.remainingEvaluationCount, 1)
    gate.finish("sent")
    await store.waitForEvaluations()
    store.retryPendingEvaluations()
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 2)
    XCTAssertFalse(store.isEvaluating)
    XCTAssertFalse(store.isSendingReminder)
    XCTAssertEqual(store.remainingEvaluationCount, 0)
  }

  private enum TestError: Error { case notification }

  @MainActor
  private final class Gate {
    let started = XCTestExpectation(description: "Async notification started")
    private var continuation: CheckedContinuation<String, Never>?
    func value() async -> String {
      await withCheckedContinuation {
        continuation = $0
        started.fulfill()
      }
    }
    func finish(_ result: String) {
      continuation?.resume(returning: result)
      continuation = nil
    }
  }

  @MainActor
  private final class Fixture {
    let suite = "SpinnerLifecycleTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let storage = MemoryStorage()
    let target = FocusTarget(id: UUID(), text: "Implement login", startedAt: Date().addingTimeInterval(-3600))
    init() {
      defaults = UserDefaults(suiteName: suite)!
      defaults.set(try! JSONEncoder().encode(target), forKey: "target.current")
      defaults.set(false, forKey: TargetPreferences.alertsEnabledKey)
      storage.cards[1] = Self.card(id: 1)
    }
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    func store() -> TargetStore {
      TargetStore(defaults: defaults, storage: storage,
        generate: { _ in XCTFail("No model evaluation"); return "invalid" })
    }
    static func card(id: Int64) -> TimelineCardWithTimestamps {
      let end = Int(Date().timeIntervalSince1970)
      return TimelineCardWithTimestamps(id: id, startTimestamp: "10:00 AM", endTimestamp: "10:05 AM",
        startTs: end - 300, endTs: end, category: "Work", subcategory: "",
        title: "Implement login", summary: "Login implementation", detailedSummary: "Implementation evidence",
        day: "2026-10-30", distractions: nil, videoSummaryURL: nil)
    }
  }

  private final class MemoryStorage: TargetStorage {
    var cards: [Int64: TimelineCardWithTimestamps] = [:]
    var assessments: [Int64: TargetAssessment] = [:]
    var saveCount = 0
    func fetchTargetAssessments() throws -> [TargetAssessment] { Array(assessments.values) }
    func targetCandidateCardIDs(since date: Date) throws -> [Int64] { cards.keys.sorted() }
    func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? { cards[id] }
    func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] { [] }
    func saveTargetAssessment(_ assessment: TargetAssessment, card: TimelineCardWithTimestamps) throws -> Bool {
      guard let current = cards[card.id], TargetStore.fingerprint(current) == TargetStore.fingerprint(card)
      else { return false }
      assessments[card.id] = assessment
      saveCount += 1
      return true
    }
  }
}
