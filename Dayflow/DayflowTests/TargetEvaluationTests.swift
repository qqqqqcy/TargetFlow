import XCTest

@testable import Dayflow

final class TargetEvaluationTests: XCTestCase {
  func testDecodeRejectsUnknownLevelAndMissingSevereReminder() throws {
    XCTAssertThrowsError(
      try TargetEvaluationResponse.parse(
        """
        {"alignment":"distracted","reason":"无关活动","reminder":"返回工作"}
        """))
    XCTAssertThrowsError(
      try TargetEvaluationResponse.parse(
        """
        {"alignment":"severe","reason":"无关活动","reminder":"  "}
        """))
    XCTAssertThrowsError(try TargetEvaluationResponse.parse("not JSON"))
    let response = try TargetEvaluationResponse.parse(
      """
      ```json
      {"alignment":"focused","reason":"正在完成目标","reminder":""}
      ```
      """)
    XCTAssertEqual(response.alignment, .focused)
  }

  func testNotificationPolicyRejectsHistoricalFutureNeutralAndCooldown() {
    let now = Date(timeIntervalSince1970: 100_000)
    func allows(_ level: TargetAlignment, age: TimeInterval, last: TimeInterval? = nil) -> Bool {
      TargetEvaluationPolicy.shouldNotify(
        alignment: level, endTime: now.addingTimeInterval(-age), now: now,
        lastReminderAt: last.map { now.addingTimeInterval(-$0) }, cooldownMinutes: 15)
    }
    XCTAssertTrue(allows(.severe, age: 60))
    XCTAssertFalse(allows(.neutral, age: 60))
    XCTAssertFalse(allows(.focused, age: 60))
    XCTAssertFalse(allows(.severe, age: 1801))
    XCTAssertFalse(allows(.severe, age: -120))
    XCTAssertFalse(allows(.severe, age: 60, last: 899))
    XCTAssertTrue(allows(.severe, age: 60, last: 900))
  }

  func testTargetBoundaryIncludesCrossingCardButExcludesPastCard() {
    let start = Date(timeIntervalSince1970: 100_000)
    let target = FocusTarget(id: UUID(), text: "实现登录", startedAt: start)
    XCTAssertFalse(TargetEvaluationPolicy.isEligible(endTime: start, target: target))
    XCTAssertTrue(
      TargetEvaluationPolicy.isEligible(endTime: start.addingTimeInterval(60), target: target))
  }

  @MainActor
  func testCrossingCardEvaluatesOnlyEvidenceAfterTargetActivation() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var receivedPrompt = ""
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { prompt in
      receivedPrompt = prompt
      return Self.focusedResponse
    }
    store.setTarget("简历优化")
    let boundary = Int(store.target!.startedAt.timeIntervalSince1970)
    fixture.storage.card = Self.card(start: boundary - 60)
    fixture.storage.observations = [
      Self.observation(start: boundary - 60, end: boundary, text: "BEFORE_TARGET"),
      Self.observation(start: boundary, end: boundary + 60, text: "STRADDLES_TARGET"),
      Self.observation(start: boundary + 60, end: boundary + 120, text: "AFTER_TARGET"),
    ]
    store.retryPendingEvaluations()
    await store.waitForEvaluations()
    XCTAssertNotNil(store.assessments[1])
    XCTAssertEqual(store.assessments[1]?.startTime, store.target?.startedAt)
    XCTAssertTrue(receivedPrompt.contains("AFTER_TARGET"))
    XCTAssertFalse(receivedPrompt.contains("BEFORE_TARGET"))
    XCTAssertFalse(receivedPrompt.contains("STRADDLES_TARGET"))
    XCTAssertFalse(receivedPrompt.contains("SwiftUI 开发"))
  }

  private static func observation(start: Int, end: Int, text: String) -> Observation {
    Observation(
      id: nil, batchId: 1, startTs: start, endTs: end,
      observation: text, metadata: nil, llmModel: nil, createdAt: nil)
  }

  @MainActor
  func testChangedTargetDiscardsInFlightResponse() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var store: TargetStore!
    store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { _ in
      store.setTarget("新的目标")
      return Self.focusedResponse
    }
    store.setTarget("实现登录")
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertTrue(store.assessments.isEmpty)
    XCTAssertTrue(fixture.storage.saved.isEmpty)
    XCTAssertEqual(store.target?.text, "新的目标")
  }

  @MainActor
  func testDeletedCardCannotReceiveAssessment() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { _ in
      fixture.storage.card = nil
      return Self.focusedResponse
    }
    store.setTarget("实现登录")
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertTrue(store.assessments.isEmpty)
  }

  @MainActor
  func testDuplicateCardDoesNotGenerateAgainAndTargetRestores() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var calls = 0
    let generate: (String) async throws -> String = { _ in
      calls += 1
      return Self.focusedResponse
    }
    let store = TargetStore(
      defaults: fixture.defaults, storage: fixture.storage, generate: generate)
    store.setTarget("实现登录")
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1, 1])
    await store.waitForEvaluations()
    let restored = TargetStore(
      defaults: fixture.defaults, storage: fixture.storage, generate: generate)
    restored.enqueue(cardIDs: [1])
    await restored.waitForEvaluations()
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(restored.target, store.target)
    XCTAssertEqual(restored.assessments[1]?.alignment, .focused)
  }

  @MainActor
  func testFailedEvaluationIsRetryableAndNotNeutral() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var calls = 0
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { _ in
      calls += 1
      return calls == 1 ? "invalid" : Self.focusedResponse
    }
    store.setTarget("实现登录")
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertNotNil(store.lastError)
    XCTAssertTrue(store.assessments.isEmpty)
    store.retryPendingEvaluations()
    await store.waitForEvaluations()
    XCTAssertNil(store.lastError)
    XCTAssertEqual(store.assessments[1]?.alignment, .focused)
  }

  @MainActor
  private func makeFixture() -> (
    defaults: UserDefaults, suite: String, storage: TargetMemoryStorage
  ) {
    let suite = "TargetEvaluationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: TargetPreferences.alertsEnabledKey)
    return (defaults, suite, TargetMemoryStorage())
  }

  private static let focusedResponse = """
    {"alignment":"focused","reason":"正在实现登录","reminder":""}
    """

  private static func card(start: Int? = nil) -> TimelineCardWithTimestamps {
    let now = start ?? (Int(Date().timeIntervalSince1970) + 2)
    return TimelineCardWithTimestamps(
      id: 1, startTimestamp: "10:00 AM", endTimestamp: "10:05 AM",
      startTs: now, endTs: now + 300, category: "Work", subcategory: "",
      title: "实现登录", summary: "编写登录页", detailedSummary: "SwiftUI 开发",
      day: "2026-10-26", distractions: nil, videoSummaryURL: nil)
  }
}

private final class TargetMemoryStorage: TargetStorage {
  var card: TimelineCardWithTimestamps?
  var saved: [TargetAssessment] = []
  var observations: [Observation] = []

  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] { observations }

  func fetchTargetAssessments() throws -> [TargetAssessment] { saved }
  func targetCandidateCardIDs(since date: Date) throws -> [Int64] { card.map { [$0.id] } ?? [] }
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? { card }
  func saveTargetAssessment(_ assessment: TargetAssessment, card: TimelineCardWithTimestamps) throws
    -> Bool
  {
    guard self.card?.id == card.id else { return false }
    saved = [assessment]
    return true
  }
}
