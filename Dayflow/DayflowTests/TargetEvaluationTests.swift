import XCTest
@testable import Dayflow

final class TargetEvaluationTests: XCTestCase {
  func testExactEventMembershipIsTheOnlyAlignmentRule() {
    let events = [FocusTargetEvent(id: UUID(), name: "实现登录", details: "必要准备"),
      FocusTargetEvent(id: UUID(), name: "准备面试", details: "")]
    for name in ["实现登录", "准备面试"] {
      XCTAssertEqual(TargetEvaluationPolicy.evaluate(category: name, events: events).alignment, .focused)
    }
    for name in ["其他", "Work", "实现登录 ", "必要准备", "__privacy__", "__unmatched__", "Idle"] {
      let response = TargetEvaluationPolicy.evaluate(category: name, events: events)
      XCTAssertEqual(response.alignment, .severe)
      XCTAssertFalse(response.reminder.isEmpty)
    }
  }

  @MainActor
  func testMembershipOverridesEvidenceAndNeverCallsModel() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage) { _ in
      XCTFail("Alignment must not call a model")
      return "invalid"
    }
    store.synchronize(events: [Self.event("实现登录"), Self.event("准备面试")])
    for kind in [ActivityEvidenceKind?.none, .unknown, .privacyRedacted, .inputInactive] {
      for category in ["实现登录", "准备面试", "其他"] {
        fixture.storage.card = Self.card(category: category, evidence: kind)
        store.enqueue(cardIDs: [1])
        await store.waitForEvaluations()
        XCTAssertEqual(store.assessments[1]?.alignment, category == "其他" ? .severe : .focused)
        XCTAssertNil(store.lastError)
      }
    }
  }

  @MainActor
  func testDisabledOrNonCurrentEventsDoNotBecomeGoalsAndAllOffSkipsEvaluation() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    var disabled = Self.event("disabled")
    disabled.eventEnabled = false
    var notCurrent = Self.event("not current")
    notCurrent.targetEnabled = false
    store.synchronize(events: [Self.event("实现登录"), disabled, notCurrent])
    XCTAssertEqual(store.target?.events?.map(\.name), ["实现登录"])
    store.synchronize(events: [disabled, notCurrent])
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertNil(store.target)
    XCTAssertTrue(store.assessments.isEmpty)
    XCTAssertNil(fixture.defaults.data(forKey: "target.current"))
  }

  @MainActor
  func testRefreshRecomputesLegacyFingerprintAndHidesChangedCardUntilRefreshed() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let card = Self.card(category: "其他")
    fixture.storage.card = card
    fixture.storage.saved = [Self.assessment(card: card, text: "实现登录", alignment: .focused)]
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    XCTAssertEqual(store.assessment(for: 1)?.alignment, .severe)
    XCTAssertNotEqual(store.assessments[1]?.fingerprint, "old-model-fingerprint")
    fixture.storage.card = Self.card(category: "实现登录")
    XCTAssertNil(store.assessment(for: 1))
    store.refreshAssessments()
    XCTAssertEqual(store.assessment(for: 1)?.alignment, .focused)
    XCTAssertEqual(fixture.storage.saved.first?.alignment, .focused)
  }

  @MainActor
  func testHistoricalGoalsUseTheirSnapshotNotTodaysGoals() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    // A historical card before today's session must keep its original goal context.
    let card = Self.card(start: 100_000, category: "旧目标")
    fixture.storage.card = card
    var historical = Self.assessment(card: card, text: "旧目标：当时的说明", alignment: .severe)
    historical.targetEvents = [FocusTargetEvent(id: UUID(), name: "旧目标", details: "当时的说明")]
    fixture.storage.saved = [historical]
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    store.synchronize(events: [Self.event("今天的目标")])
    store.refreshAssessments()
    XCTAssertEqual(store.assessments[1]?.targetText, "旧目标：当时的说明")
    XCTAssertEqual(store.assessments[1]?.alignment, .focused)
    XCTAssertEqual(store.assessments[1]?.targetID, historical.targetID)
  }

  @MainActor
  func testLegacyHistoricalTextMatchesNamesNotDescriptionOrCurrentTarget() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.storage.card = Self.card(start: 100_000, category: "准备面试")
    fixture.storage.saved = [Self.assessment(card: fixture.storage.card!,
      text: "实现登录：准备面试\n写文档：整理资料", alignment: .focused)]
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    XCTAssertEqual(store.assessments[1]?.alignment, .severe)
    fixture.storage.card = Self.card(start: 100_000, category: "写文档")
    store.refreshAssessments()
    XCTAssertEqual(store.assessments[1]?.alignment, .focused)
  }

  @MainActor
  func testSwitchGoalsRecomputesEligibleCardsAndCosmeticsPreserveSession() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    var event = Self.event("实现登录")
    store.synchronize(events: [event])
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(store.assessments[1]?.alignment, .focused)
    let original = store.target
    event.colorHex = "#FFFFFF"
    event.order = 10
    store.synchronize(events: [event])
    XCTAssertEqual(store.target, original)
    store.synchronize(events: [Self.event("准备面试")])
    await store.waitForEvaluations()
    XCTAssertEqual(store.assessments[1]?.alignment, .severe)
    XCTAssertEqual(store.assessments[1]?.targetID, store.target?.id)
  }

  @MainActor
  func testRestoredGoalUsesDeterministicAssessmentWithoutModel() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let events = [Self.event("实现登录")]
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    store.synchronize(events: events)
    fixture.storage.card = Self.card()
    store.enqueue(cardIDs: [1, 1])
    await store.waitForEvaluations()
    let restored = TargetStore(defaults: fixture.defaults, storage: fixture.storage)
    restored.synchronize(events: events)
    restored.enqueue(cardIDs: [1])
    await restored.waitForEvaluations()
    XCTAssertEqual(restored.target, store.target)
    XCTAssertEqual(restored.assessments[1]?.alignment, .focused)
  }

  @MainActor
  func testDistractedReminderDeduplicatesAndFocusedNeverNotifies() async {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.defaults.set(true, forKey: TargetPreferences.alertsEnabledKey)
    var notifications = 0
    let store = TargetStore(defaults: fixture.defaults, storage: fixture.storage,
      automaticReminders: AutomaticReminderState(isRecording: true),
      notify: { _, body, allowed in
        guard allowed() else { return false }
        XCTAssertFalse(body.isEmpty)
        notifications += 1
        return true
      })
    store.synchronize(events: [Self.event("实现登录")])
    let start = Int(Date().timeIntervalSince1970) - 299
    fixture.storage.card = Self.card(start: start, category: "其他")
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 1)
    fixture.storage.card = Self.card(start: start + 1, category: "实现登录")
    store.enqueue(cardIDs: [1])
    await store.waitForEvaluations()
    XCTAssertEqual(notifications, 1)
  }

  func testNotificationPolicyRejectsFocusedAndStaleEvents() {
    let now = Date()
    XCTAssertTrue(TargetEvaluationPolicy.shouldNotify(alignment: .severe, endTime: now, now: now))
    XCTAssertFalse(TargetEvaluationPolicy.shouldNotify(alignment: .focused, endTime: now, now: now))
    XCTAssertFalse(TargetEvaluationPolicy.shouldNotify(alignment: .severe,
      endTime: now.addingTimeInterval(-1801), now: now))
  }

  @MainActor
  private func makeFixture() -> (defaults: UserDefaults, suite: String, storage: TargetMemoryStorage) {
    let suite = "TargetEvaluationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: TargetPreferences.alertsEnabledKey)
    return (defaults, suite, TargetMemoryStorage())
  }

  private static func event(_ name: String) -> TimelineCategory {
    TimelineCategory(name: name, colorHex: "#B984FF", order: 0, targetEnabled: true)
  }

  private static func assessment(card: TimelineCardWithTimestamps, text: String,
    alignment: TargetAlignment) -> TargetAssessment {
    TargetAssessment(cardID: card.id, targetID: UUID(), targetText: text,
      cardTitle: card.title, fingerprint: "old-model-fingerprint",
      startTime: Date(timeIntervalSince1970: Double(card.startTs)),
      endTime: Date(timeIntervalSince1970: Double(card.endTs)), alignment: alignment,
      reason: "Old contradictory model judgment", reminder: "Old reminder")
  }

  private static func card(start: Int? = nil, category: String = "实现登录",
    evidence: ActivityEvidenceKind? = nil) -> TimelineCardWithTimestamps {
    let start = start ?? Int(Date().timeIntervalSince1970) + 2
    return TimelineCardWithTimestamps(id: 1, startTimestamp: "10:00 AM", endTimestamp: "10:05 AM",
      startTs: start, endTs: start + 300, category: category, subcategory: "",
      title: "实现登录", summary: "编写登录页", detailedSummary: "SwiftUI 开发", day: "2026-10-26",
      distractions: nil, videoSummaryURL: nil, evidenceKind: evidence)
  }
}

private final class TargetMemoryStorage: TargetStorage {
  var card: TimelineCardWithTimestamps?
  var saved: [TargetAssessment] = []
  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] { [] }
  func fetchTargetAssessments() throws -> [TargetAssessment] { saved }
  func targetCandidateCardIDs(since date: Date) throws -> [Int64] { card.map { [$0.id] } ?? [] }
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? {
    card?.id == id ? card : nil
  }
  func saveTargetAssessment(_ assessment: TargetAssessment, card: TimelineCardWithTimestamps) throws -> Bool {
    guard let current = self.card, current.id == card.id,
      TargetStore.fingerprint(current) == TargetStore.fingerprint(card) else { return false }
    saved = [assessment]
    return true
  }
}
