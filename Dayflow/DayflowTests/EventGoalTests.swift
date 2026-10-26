import XCTest

@testable import Dayflow

final class EventGoalTests: XCTestCase {
  @MainActor
  func testMultipleSwitchesPersistAndSystemEventCannotBeEnabled() throws {
    let suite = "EventGoalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var lastEvents: [TimelineCategory] = []
    let store = CategoryStore(defaults: defaults, onEventsChanged: { lastEvents = $0 })
    let editable = store.editableCategories
    XCTAssertGreaterThanOrEqual(editable.count, 2)
    store.setCurrentTarget(true, for: editable[0].id)
    store.setCurrentTarget(true, for: editable[1].id)
    XCTAssertEqual(store.currentTargets.count, 2)
    XCTAssertEqual(lastEvents.filter(\.isCurrentTarget).count, 2)
    let idle = try XCTUnwrap(store.idleCategory)
    store.setCurrentTarget(true, for: idle.id)
    XCTAssertFalse(store.idleCategory!.isCurrentTarget)

    let restored = CategoryStore(defaults: defaults, onEventsChanged: { _ in })
    XCTAssertEqual(Set(restored.currentTargets.map(\.id)), Set(store.currentTargets.map(\.id)))
    restored.setCurrentTarget(false, for: editable[0].id)
    restored.removeCategory(id: editable[1].id)
    XCTAssertTrue(restored.currentTargets.isEmpty)
    let reloaded = CategoryStore(defaults: defaults, onEventsChanged: { _ in })
    XCTAssertTrue(reloaded.currentTargets.isEmpty)
  }

  @MainActor
  func testLegacyRunningTargetMigratesOnceAndKeepsExistingEvents() throws {
    let suite = "EventGoalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = TimelineCategory(name: "原有事件", colorHex: "#FFFFFF", order: 0)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    defaults.set(try encoder.encode([original]), forKey: CategoryStore.StoreKeys.categories)
    let legacy = FocusTarget(id: UUID(), text: "修复登录，允许查询文档", startedAt: Date())
    defaults.set(try JSONEncoder().encode(legacy), forKey: "target.current")

    let store = CategoryStore(defaults: defaults, onEventsChanged: { _ in })
    XCTAssertTrue(store.categories.contains { $0.id == original.id })
    XCTAssertEqual(store.currentTargets.count, 1)
    XCTAssertEqual(store.currentTargets.first?.id, legacy.id)
    XCTAssertEqual(store.currentTargets.first?.details, legacy.text)
    let restored = CategoryStore(defaults: defaults, onEventsChanged: { _ in })
    XCTAssertEqual(restored.categories.count, store.categories.count)
    XCTAssertEqual(restored.currentTargets.count, 1)
  }

  func testSummaryDefaultsFollowCurrentTargetSwitchesInsteadOfNames() {
    let enabled = TimelineCategory(
      name: "Distraction", colorHex: "#FFFFFF", order: 2, targetEnabled: true)
    let disabled = TimelineCategory(name: "Work", colorHex: "#FFFFFF", order: 0)
    let otherEnabled = TimelineCategory(
      name: "准备面试", colorHex: "#FFFFFF", order: 1, targetEnabled: true)
    let idle = TimelineCategory(
      name: "Idle", colorHex: "#FFFFFF", order: 3, isIdle: true, targetEnabled: true)
    let system = TimelineCategory(
      name: "System", colorHex: "#FFFFFF", order: 4, isSystem: true)

    let plan = DayGoalPlan.defaultPlan(
      day: "2026-10-27", categories: [enabled, disabled, idle, system, otherEnabled])

    XCTAssertEqual(
      plan.focusCategories.map(\.categoryID), [otherEnabled, enabled].map { $0.id.uuidString })
    XCTAssertEqual(plan.distractionCategories.map(\.categoryID), [disabled.id.uuidString])
  }

  func testSummaryDefaultsWithNoCurrentTargetsSelectAllEditableEventsAsDistractions() {
    var event = TimelineCategory(name: "Work", colorHex: "#FFFFFF", order: 0)
    let offPlan = DayGoalPlan.defaultPlan(day: "2026-10-27", categories: [event])
    XCTAssertTrue(offPlan.focusCategories.isEmpty)
    XCTAssertEqual(offPlan.distractionCategories.map(\.categoryID), [event.id.uuidString])

    event.targetEnabled = true
    let onPlan = DayGoalPlan.defaultPlan(day: "2026-10-27", categories: [event])
    XCTAssertEqual(onPlan.focusCategories.map(\.categoryID), [event.id.uuidString])
    XCTAssertTrue(onPlan.distractionCategories.isEmpty)
  }

  func testOldEventJSONDecodesWithGoalOff() throws {
    let original = TimelineCategory(name: "已有事件", colorHex: "#FFFFFF", order: 0)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "targetEnabled")
    let decoded = try JSONDecoder().decode(
      TimelineCategory.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(decoded.id, original.id)
    XCTAssertFalse(decoded.isCurrentTarget)
  }

  func testEventPromptsKeepLabelsSecondaryAndDoNotInferGoalAlignment() {
    struct PromptBuilder: TimelineOutputSupporting {}
    let prompt = PromptBuilder().categoriesSection(from: [
      LLMCategoryDescriptor(
        id: UUID(), name: "实现登录", colorHex: "#FFFFFF",
        description: "修复 OAuth 回调", isSystem: false, isIdle: false)
    ])
    XCTAssertTrue(prompt.contains("EVENT-FIRST WRITING"))
    XCTAssertTrue(prompt.contains("Goal alignment is evaluated separately"))
    XCTAssertTrue(prompt.contains("修复 OAuth 回调"))
    XCTAssertTrue(prompt.contains("Allowed values: [\"实现登录\"]"))
    XCTAssertFalse(CodexTimelinePrompt.additionalRules.contains("the card is that work"))
  }
}
