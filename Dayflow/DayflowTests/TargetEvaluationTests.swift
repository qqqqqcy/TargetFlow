import XCTest

@testable import Dayflow

final class TargetEvaluationTests: XCTestCase {
  @MainActor
  func testEvaluationPromptUsesSelectedOutputLanguageAndStableJSONValues() {
    let target = FocusTarget(id: UUID(), text: "Prepare for an interview", startedAt: .distantPast)
    for language in ["English", "Simplified Chinese"] {
      let prompt = TargetStore.prompt(target: target, card: Self.card(), outputLanguage: language)
      XCTAssertTrue(prompt.contains("Write reason and reminder in \(language)."))
      XCTAssertTrue(prompt.contains("\"alignment\":\"focused|neutral|severe\""))
      XCTAssertFalse(prompt.contains("Chinese characters"))
    }
  }

  func testDecodeRequiresRemindersForBothOffTrackStates() throws {
    for alignment in ["neutral", "severe", "unknown"] {
      XCTAssertThrowsError(
        try TargetEvaluationResponse.parse(
          "{\"alignment\":\"\(alignment)\",\"reason\":\"观察到事件\",\"reminder\":\" \"}"))
    }
    XCTAssertThrowsError(try TargetEvaluationResponse.parse("not JSON"))
    let response = try TargetEvaluationResponse.parse("```json\n" + Self.focusedResponse + "\n```")
    XCTAssertEqual(response.alignment, .focused)
    XCTAssertEqual(try TargetEvaluationResponse.parse(Self.neutralResponse).alignment, .neutral)
  }

  func testNotificationPolicyAllowsNeutralAndDistractionButNotFocusOrStaleEvents() {
    let now = Date(timeIntervalSince1970: 100_000)
    func allows(_ level: TargetAlignment, age: TimeInterval) -> Bool {
      TargetEvaluationPolicy.shouldNotify(
        alignment: level, endTime: now.addingTimeInterval(-age), now: now)
    }
    XCTAssertTrue(allows(.severe, age: 60))
    XCTAssertTrue(allows(.neutral, age: 60))
    XCTAssertFalse(allows(.focused, age: 60))
    XCTAssertFalse(allows(.severe, age: 1801))
    XCTAssertFalse(allows(.neutral, age: -120))
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
    store.synchronize(events: [Self.event("简历优化")])
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

  @MainActor
  func testMultipleGoalsExcludeDisabledEventsAndMatchingEitherIsFocused() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var receivedPrompt = ""
    let events = [
      Self.event("实现登录"), Self.event("准备面试"), Self.event("DISABLED_EVENT", enabled: false),
    ]
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { prompt in
      receivedPrompt = prompt
      return Self.focusedResponse
    }
    store.synchronize(events: events)
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(store.target?.events?.count, 2)
    XCTAssertTrue(receivedPrompt.contains("实现登录"))
    XCTAssertTrue(receivedPrompt.contains("准备面试"))
    XCTAssertFalse(receivedPrompt.contains("DISABLED_EVENT"))
    XCTAssertTrue(receivedPrompt.contains("advancing ANY ONE goal is focused"))
    XCTAssertFalse(receivedPrompt.contains("\"category\""))
    XCTAssertEqual(store.assessments[1]?.alignment, .focused)
  }

  @MainActor
  func testChangingOrDisablingGoalsDiscardsInFlightResponse() async {
    for disableAll in [false, true] {
      let fixture = makeFixture()
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      var store: TargetStore!
      store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { _ in
        store.synchronize(events: disableAll ? [] : [Self.event("新的目标")])
        return Self.focusedResponse
      }
      store.synchronize(events: [Self.event("实现登录")])
      fixture.storage.card = Self.card()
      store.enqueue(cardIDs: [1])
      await store.waitForEvaluations()
      XCTAssertTrue(store.assessments.isEmpty)
      XCTAssertTrue(fixture.storage.saved.isEmpty)
      XCTAssertEqual(store.target?.text, disableAll ? nil : "新的目标")
    }
  }

  @MainActor
  func testNoEnabledGoalsSkipsEvaluationAndClearsSession() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var calls = 0
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { _ in
      calls += 1
      return Self.focusedResponse
    }
    store.synchronize(events: [Self.event("实现登录")])
    store.synchronize(events: [Self.event("实现登录", enabled: false)])
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(calls, 0)
    XCTAssertNil(store.target)
    XCTAssertNil(fixture.defaults.data(forKey: "target.current"))
  }

  @MainActor
  func testEventCosmeticsPreserveSessionButGoalEditsRestartIt() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    var events = [Self.event("实现登录"), Self.event("准备面试")]
    store.synchronize(events: events)
    let original = store.target
    events[0].colorHex = "#FFFFFF"
    events[0].order = 10
    store.synchronize(events: events.reversed())
    XCTAssertEqual(store.target, original)
    events[0].details = "只处理密码登录"
    store.synchronize(events: events)
    XCTAssertNotEqual(store.target?.id, original?.id)
  }

  @MainActor
  func testDeletedCardCannotReceiveAssessment() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { _ in
      fixture.storage.card = nil
      return Self.focusedResponse
    }
    store.synchronize(events: [Self.event("实现登录")])
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertTrue(store.assessments.isEmpty)
  }

  @MainActor
  func testDuplicateCardDoesNotGenerateAgainAndGoalsRestore() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var calls = 0
    let generate: (String) async throws -> String = { _ in
      calls += 1
      return Self.focusedResponse
    }
    let events = [Self.event("实现登录"), Self.event("准备面试")]
    let store = TargetStore(
      defaults: fixture.defaults, storage: fixture.storage, generate: generate)
    store.synchronize(events: events)
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1, 1])
    await store.waitForEvaluations()
    let restored = TargetStore(
      defaults: fixture.defaults, storage: fixture.storage, generate: generate)
    restored.synchronize(events: events)
    restored.enqueue(cardIDs: [1])
    await restored.waitForEvaluations()
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(restored.target, store.target)
    XCTAssertEqual(restored.assessments[1]?.alignment, .focused)
  }

  @MainActor
  func testNeutralAndDistractionNotifyWithoutCooldownAndDuplicateDoesNot() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.defaults.set(true, forKey: TargetPreferences.alertsEnabledKey)
    // An old cooldown preference must have no effect.
    fixture.defaults.set(30, forKey: "target.cooldownMinutes")
    fixture.defaults.set(Date(), forKey: "target.lastReminderAt")
    var notifications = 0
    var output = Self.neutralResponse
    let store = TargetStore(
      defaults: fixture.defaults, storage: fixture.storage,
      notify: { _, body, shouldSend in
        guard shouldSend() else { return false }
        XCTAssertFalse(body.isEmpty)
        notifications += 1
        return true
      },
      generate: { _ in output })
    store.synchronize(events: [Self.event("实现登录")])
    let now = Int(Date().timeIntervalSince1970)
    fixture.storage.card = Self.card(start: now - 299)
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 1)
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 1)
    // A new segment arrives within seconds; it is not suppressed by a timer.
    output = "{\"alignment\":\"severe\",\"reason\":\"持续看无关视频\",\"reminder\":\"回到登录页\"}"
    fixture.storage.card = Self.card(start: now - 298)
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 2)
    output = Self.focusedResponse
    fixture.storage.card = Self.card(start: now - 297)
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 2)
    fixture.defaults.set(false, forKey: TargetPreferences.alertsEnabledKey)
    output = Self.neutralResponse
    fixture.storage.card = Self.card(start: now - 296)
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 2)
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
    store.synchronize(events: [Self.event("实现登录")])
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

  private static func event(_ name: String, enabled: Bool = true) -> TimelineCategory {
    TimelineCategory(name: name, colorHex: "#B984FF", order: 0, targetEnabled: enabled)
  }

  private static let focusedResponse = """
    {"alignment":"focused","reason":"正在实现登录","reminder":""}
    """
  private static let neutralResponse = """
    {"alignment":"neutral","reason":"短暂休息","reminder":"准备好后继续实现登录页"}
    """

  private static func observation(start: Int, end: Int, text: String) -> Observation {
    Observation(
      id: nil, batchId: 1, startTs: start, endTs: end,
      observation: text, metadata: nil, llmModel: nil, createdAt: nil)
  }

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
    guard self.card?.id == card.id,
      TargetStore.fingerprint(self.card!) == TargetStore.fingerprint(card)
    else { return false }
    saved = [assessment]
    return true
  }
}
