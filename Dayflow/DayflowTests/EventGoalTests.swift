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

  @MainActor
  func testAddingAnEventRequiresARealNameAndPersistsItsDefinitionAtomically() throws {
    let suite = "EventGoalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var changes: [[TimelineCategory]] = []
    let store = CategoryStore(defaults: defaults, onEventsChanged: { changes.append($0) })
    let before = changes.count
    for name in ["", "新事件", "新事件 2", "New event", "New event 3", "其他"] {
      XCTAssertNil(store.addCategory(name: name, details: "draft", targetEnabled: true))
    }
    XCTAssertEqual(changes.count, before)
    let id = try XCTUnwrap(store.addCategory(
      name: "  学习示例项目  ", details: "研究示例项目的执行与验收流程", targetEnabled: true))
    XCTAssertEqual(changes.count, before + 1)
    let saved = try XCTUnwrap(changes.last?.first(where: { $0.id == id }))
    XCTAssertEqual(saved.name, "学习示例项目")
    XCTAssertEqual(saved.details, "研究示例项目的执行与验收流程")
    XCTAssertTrue(saved.isCurrentTarget)
    let restored = CategoryStore(defaults: defaults, onEventsChanged: { _ in })
    let reloaded = try XCTUnwrap(restored.categories.first(where: { $0.id == id }))
    XCTAssertEqual(reloaded.name, saved.name)
    XCTAssertEqual(reloaded.details, saved.details)
    XCTAssertEqual(reloaded.targetEnabled, saved.targetEnabled)
    XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, saved.createdAt.timeIntervalSince1970, accuracy: 1)
  }

  @MainActor
  func testSavedPlaceholderCannotClassifyActivityButKeepsItsGoalDefinition() throws {
    let placeholder = TimelineCategory(
      name: "新事件", colorHex: "#FFFFFF", details: "学习示例项目的设计与实现",
      order: 0, isNew: false, targetEnabled: true)
    let named = TimelineCategory(name: "文档整理", colorHex: "#FFFFFF", order: 1)
    let definitions = CategoryStore.descriptorsForLLM(categories: [placeholder, named])
    XCTAssertFalse(definitions.contains { $0.id == placeholder.id })
    XCTAssertTrue(definitions.contains { $0.id == named.id })
    XCTAssertEqual(definitions.filter(\.isIdle).count, 1)
    XCTAssertTrue(placeholder.isCurrentTarget)
    XCTAssertEqual(placeholder.details, "学习示例项目的设计与实现")
    let displayed = try XCTUnwrap(TimelineEventDisplay.reservedCategory(placeholder.name))
    XCTAssertTrue(displayed.isIdle)
    XCTAssertEqual(displayed.name, String(localized: "Other"))
    XCTAssertEqual(TimelineEventDisplay.canonicalCategoryKey(placeholder.name), "idle")
    XCTAssertEqual(categoryFilterKey(placeholder.name), categoryFilterKey("其他"))
    let suite = "EventGoalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    defaults.set(try encoder.encode([placeholder, named]), forKey: CategoryStore.StoreKeys.categories)
    let store = CategoryStore(defaults: defaults, onEventsChanged: { _ in })
    XCTAssertTrue(store.currentTargets.contains { $0.id == placeholder.id })
    XCTAssertFalse(store.matchableCategories.contains { $0.id == placeholder.id })
    XCTAssertTrue(store.matchableCategories.contains { $0.id == named.id })
  }

  func testPlaceholderAndUnknownModelLabelsUseOtherEvenWhenPlaceholderWasConfigured() {
    let placeholder = LLMCategoryDescriptor(id: UUID(), name: "新事件", colorHex: "#FFFFFF",
      description: "旧的占位目标描述", isSystem: false, isIdle: false)
    let named = LLMCategoryDescriptor(id: UUID(), name: "学习示例", colorHex: "#FFFFFF",
      description: "研究示例项目", isSystem: false, isIdle: false)
    let policy = TimelineOutputPolicy()
    for raw in ["新事件", "新事件 2", "NEW EVENT 3", "Other", "其他", "无法分类", ""] {
      XCTAssertEqual(policy.normalizeCategory(raw, descriptors: [placeholder, named]), "Idle")
      XCTAssertEqual(GeminiDirectProvider(apiKey: "synthetic").normalizeCategory(
        raw, descriptors: [placeholder, named]), "Idle")
    }
    XCTAssertEqual(policy.normalizeCategory("学习示例", descriptors: [placeholder, named]), named.name)
    let prompt = policy.categoriesSection(from: [placeholder, named])
    XCTAssertFalse(prompt.contains("旧的占位目标描述"))
    XCTAssertTrue(prompt.contains("Configured values: [\"学习示例\"]"))
    for name in ["New event research", "新事件研究", "研究新事件"] {
      XCTAssertFalse(TimelineEventDisplay.isPlaceholderName(name))
    }
  }

  func testVisibleOtherKeepsRecordedTimeWithoutBecomingGoalOrInactivity() {
    let placeholder = TimelineCategory(name: "新事件", colorHex: "#FFFFFF", order: 0, targetEnabled: true)
    let categories = CategoryPersistence.ensureIdleCategoryPresent(in: [placeholder])
    func activity(_ category: String, _ start: String, _ end: String, _ evidence: ActivityEvidenceKind) -> TimelineCard {
      TimelineCard(recordId: nil, batchId: nil, startTimestamp: start, endTimestamp: end,
        category: category, subcategory: "", title: "真实活动", summary: "", detailedSummary: "",
        day: "2026-11-03", distractions: nil, videoSummaryURL: nil,
        otherVideoSummaryURLs: nil, appSites: nil, evidenceKind: evidence)
    }
    let input = DaySummaryStats.precomputeCardDurations([
      activity("Idle", "9:00 AM", "9:10 AM", .visible),
      activity("新事件", "9:10 AM", "9:20 AM", .visible),
      activity("Idle", "9:20 AM", "9:30 AM", .inputInactive),
      activity("System", "9:30 AM", "9:40 AM", .visible)])
    let durations = DaySummaryStats.computeCategoryDurations(from: input, categories: categories)
    XCTAssertEqual(durations.count, 1)
    XCTAssertEqual(durations.first?.name, String(localized: "Other"))
    XCTAssertEqual(durations.first?.duration, 1200)
    XCTAssertEqual(DaySummaryStats.computeTotalCapturedTime(from: input, categories: categories), 1200)
    XCTAssertEqual(DaySummaryStats.computeTotalFocusTime(from: input,
      snapshots: [DayGoalCategorySnapshot(category: placeholder, sortOrder: 0)], categories: categories), 0)
  }

  func testEventPromptsKeepLabelsSecondaryAndDoNotInferGoalAlignment() {
    struct PromptBuilder: TimelineOutputSupporting {}
    let prompt = PromptBuilder().categoriesSection(from: [
      LLMCategoryDescriptor(
        id: UUID(), name: "实现登录", colorHex: "#FFFFFF",
        description: "修复 OAuth 回调", isSystem: false, isIdle: false)
    ])
    XCTAssertTrue(prompt.contains("EVENT-FIRST WRITING"))
    XCTAssertTrue(prompt.contains("derives focus from membership"))
    XCTAssertTrue(prompt.contains("Unmatched events are never counted as focused"))
    XCTAssertTrue(prompt.contains("Never invent progress or force an off-topic event"))
    XCTAssertTrue(prompt.contains("修复 OAuth 回调"))
    XCTAssertTrue(prompt.contains("Configured values: [\"实现登录\"]"))
    XCTAssertTrue(prompt.contains("or Idle"))
    XCTAssertFalse(CodexTimelinePrompt.additionalRules.contains("the card is that work"))
  }
}
