import XCTest

@testable import Dayflow

final class EventEnabledTests: XCTestCase {
  func testLegacyDefinitionsDefaultToEnabledWithoutEnablingGoal() throws {
    let original = TimelineCategory(name: "Existing event", colorHex: "#FFFFFF", order: 0)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "eventEnabled")
    object.removeValue(forKey: "targetEnabled")
    let decoded = try JSONDecoder().decode(
      TimelineCategory.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.eventEnabled)
    XCTAssertTrue(decoded.isEventEnabled)
    XCTAssertTrue(decoded.isClassificationCandidate)
    XCTAssertFalse(decoded.isCurrentTarget)
  }

  @MainActor
  func testEventAndGoalSwitchesPersistIndependentlyAndNotifyConsumers() throws {
    let suite = "EventEnabledTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var changes: [[TimelineCategory]] = []
    let store = CategoryStore(defaults: defaults, onEventsChanged: { changes.append($0) })
    let event = try XCTUnwrap(store.editableCategories.first)
    store.setCurrentTarget(true, for: event.id)
    store.setEventEnabled(false, for: event.id)
    let saved = try XCTUnwrap(changes.last?.first { $0.id == event.id })
    XCTAssertFalse(saved.isEventEnabled)
    XCTAssertTrue(saved.isCurrentTarget)
    XCTAssertFalse(store.matchableCategories.contains { $0.id == event.id })
    XCTAssertFalse(store.currentTargets.contains { $0.id == event.id })
    XCTAssertFalse(CategoryStore.descriptorsForLLM(categories: store.categories).contains { $0.id == event.id })

    let restored = CategoryStore(defaults: defaults, onEventsChanged: { _ in })
    XCTAssertFalse(try XCTUnwrap(restored.categories.first { $0.id == event.id }).isEventEnabled)
    restored.setCurrentTarget(false, for: event.id)
    XCTAssertFalse(try XCTUnwrap(restored.categories.first { $0.id == event.id }).isEventEnabled)
    restored.setEventEnabled(true, for: event.id)
    XCTAssertTrue(restored.matchableCategories.contains { $0.id == event.id })
    XCTAssertTrue(restored.currentTargets.isEmpty)
    let idle = try XCTUnwrap(restored.idleCategory)
    restored.setEventEnabled(false, for: idle.id)
    XCTAssertTrue(try XCTUnwrap(restored.idleCategory).isEventEnabled)
  }

  @MainActor
  func testNewDisabledEventIsSavedAtomicallyAndRemainsAvailableToHistory() throws {
    let suite = "EventEnabledTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var changes: [[TimelineCategory]] = []
    let store = CategoryStore(defaults: defaults, onEventsChanged: { changes.append($0) })
    let before = changes.count
    let id = try XCTUnwrap(store.addCategory(
      name: "Archived project", details: "Historical definition", targetEnabled: true,
      eventEnabled: false))
    XCTAssertEqual(changes.count, before + 1)
    let event = try XCTUnwrap(changes.last?.first { $0.id == id })
    XCTAssertFalse(event.isClassificationCandidate)
    XCTAssertTrue(event.isCurrentTarget)
    XCTAssertEqual(firstCategoryLookup(from: store.categories, normalizedKey: { $0.lowercased() })[
      "archived project"]?.id, id)
    let persisted = CategoryPersistence.loadPersistedCategories(defaults: defaults)
    XCTAssertEqual(persisted.first { $0.id == id }?.eventEnabled, false)
    XCTAssertFalse(CategoryStore.descriptorsForLLM(categories: persisted).contains { $0.id == id })
  }

  func testDisabledEventsAreExcludedWhileFallbackAndOtherEnabledEventsRemain() {
    let disabled = TimelineCategory(
      name: "Disabled", colorHex: "#FFFFFF", order: 0, eventEnabled: false)
    let enabled = TimelineCategory(name: "Enabled", colorHex: "#FFFFFF", order: 1)
    let idle = TimelineCategory(
      name: "Idle", colorHex: "#FFFFFF", order: 2, isSystem: true, isIdle: true,
      eventEnabled: false)
    let descriptors = CategoryStore.descriptorsForLLM(categories: [disabled, enabled, idle])
    XCTAssertEqual(descriptors.map(\.id), [enabled.id, idle.id])
    let policy = TimelineOutputPolicy()
    XCTAssertEqual(policy.normalizeCategory("Disabled", descriptors: descriptors), "Idle")
    XCTAssertEqual(policy.normalizeCategory("Enabled", descriptors: descriptors), "Enabled")
    XCTAssertFalse(policy.categoriesSection(from: descriptors).contains("Disabled"))
  }
}
