import Foundation
import SwiftUI

struct TimelineCategory: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var colorHex: String
  var details: String
  var order: Int
  var isSystem: Bool
  var isIdle: Bool
  var isNew: Bool
  var createdAt: Date
  var updatedAt: Date
  // Optional for backwards-compatible decoding of existing event definitions.
  var targetEnabled: Bool?

  var isCurrentTarget: Bool { !isSystem && !isIdle && targetEnabled == true }

  init(
    id: UUID = UUID(),
    name: String,
    colorHex: String,
    details: String = "",
    order: Int,
    isSystem: Bool = false,
    isIdle: Bool = false,
    isNew: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    targetEnabled: Bool = false
  ) {
    self.id = id
    self.name = name
    self.colorHex = colorHex
    self.details = details
    self.order = order
    self.isSystem = isSystem
    self.isIdle = isIdle
    self.isNew = isNew
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.targetEnabled = targetEnabled
  }
}

struct LLMCategoryDescriptor: Codable, Equatable, Hashable, Sendable {
  let id: UUID
  let name: String
  let colorHex: String
  let description: String?
  let isSystem: Bool
  let isIdle: Bool
}

func firstCategoryLookup(
  from categories: [TimelineCategory],
  normalizedKey: (String) -> String
) -> [String: TimelineCategory] {
  var lookup: [String: TimelineCategory] = [:]
  lookup.reserveCapacity(categories.count)

  for category in categories {
    let key = normalizedKey(category.name)
    if lookup[key] == nil {
      lookup[key] = category
    }
  }

  return lookup
}

@MainActor
final class CategoryStore: ObservableObject {
  static let shared = CategoryStore()
  enum StoreKeys {
    static let categories = "colorCategories"
    static let hasUsedApp = "hasUsedApp"
  }

  @Published private(set) var categories: [TimelineCategory] = []

  private let defaults: UserDefaults
  private let onEventsChanged: @MainActor ([TimelineCategory]) -> Void

  init(
    defaults: UserDefaults = AppStoragePaths.defaults,
    onEventsChanged: @escaping @MainActor ([TimelineCategory]) -> Void = {
      TargetStore.shared.synchronize(events: $0)
    }
  ) {
    self.defaults = defaults
    self.onEventsChanged = onEventsChanged
    load()
    migrateLegacyTarget()
    onEventsChanged(categories)
  }

  var currentTargets: [TimelineCategory] {
    editableCategories.filter(\.isCurrentTarget)
  }

  func setCurrentTarget(_ enabled: Bool, for id: UUID) {
    guard let event = categories.first(where: { $0.id == id }),
      !event.isSystem, !event.isIdle, event.isCurrentTarget != enabled
    else { return }
    updateCategory(id: id) { $0.targetEnabled = enabled }
  }

  var editableCategories: [TimelineCategory] {
    categories.filter { !$0.isSystem }.sorted { $0.order < $1.order }
  }

  var idleCategory: TimelineCategory? {
    categories.first(where: { $0.isIdle })
  }

  private static let newCategoryColors = [
    "#6A7EFF", "#56CFEE", "#C787F7", "#FFAE8C", "#ADE3E3", "#F6C85F",
  ]

  private func colorForNewCategory() -> String {
    let usedColors = Set(categories.filter { !$0.isSystem && !$0.isIdle }.map(\.colorHex))
    return Self.newCategoryColors.first(where: { !usedColors.contains($0) })
      ?? Self.newCategoryColors[categories.count % Self.newCategoryColors.count]
  }

  func addCategory(name: String, colorHex: String? = nil) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let nextOrder = (categories.map { $0.order }.max() ?? -1) + 1
    let now = Date()
    let category = TimelineCategory(
      name: trimmed,
      colorHex: colorHex ?? colorForNewCategory(),
      details: "",
      order: nextOrder,
      isSystem: false,
      isIdle: false,
      isNew: true,
      createdAt: now,
      updatedAt: now
    )
    categories.append(category)
    save()

    if defaults.bool(forKey: StoreKeys.hasUsedApp) == false {
      defaults.set(true, forKey: StoreKeys.hasUsedApp)
    }
  }

  func updateCategory(id: UUID, mutate: (inout TimelineCategory) -> Void) {
    guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
    var category = categories[idx]
    mutate(&category)
    category.updatedAt = Date()
    category.isNew = false
    categories[idx] = category
    save()
  }

  func assignColor(_ hex: String, to id: UUID) {
    updateCategory(id: id) { cat in
      cat.colorHex = hex
    }
  }

  func updateDetails(_ details: String, for id: UUID) {
    updateCategory(id: id) { cat in
      cat.details = details
    }
  }

  func renameCategory(id: UUID, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    updateCategory(id: id) { cat in
      cat.name = trimmed
    }
  }

  func removeCategory(id: UUID) {
    guard let category = categories.first(where: { $0.id == id }) else { return }
    guard category.isSystem == false else { return }
    categories.removeAll { $0.id == id }
    save()
  }

  /// Moves an editable category into the slot currently held by another one,
  /// then renumbers `order` so editable categories run 0..<n and Idle stays last.
  func moveCategory(id: UUID, toPositionOf targetID: UUID) {
    var ordered = editableCategories
    guard id != targetID,
      let fromIndex = ordered.firstIndex(where: { $0.id == id }),
      let toIndex = ordered.firstIndex(where: { $0.id == targetID })
    else { return }

    ordered.move(
      fromOffsets: IndexSet(integer: fromIndex),
      toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
    )

    for (newOrder, category) in ordered.enumerated() {
      guard let idx = categories.firstIndex(where: { $0.id == category.id }) else { continue }
      categories[idx].order = newOrder
    }
    for idx in categories.indices where categories[idx].isSystem {
      categories[idx].order = ordered.count
    }
    save()
  }

  func persist() {
    save()
  }

  private func load() {
    let decoded = CategoryPersistence.loadPersistedCategories(defaults: defaults)
    let effective = decoded.isEmpty ? CategoryPersistence.defaultCategories : decoded
    categories = CategoryPersistence.ensureIdleCategoryPresent(in: effective)
  }

  private func migrateLegacyTarget() {
    let migrationKey = "target.migratedToEvents"
    guard !defaults.bool(forKey: migrationKey) else { return }
    if let data = defaults.data(forKey: "target.current"),
      let legacy = try? JSONDecoder().decode(FocusTarget.self, from: data),
      legacy.events == nil
    {
      // Preserve a running target as an enabled event instead of silently losing it.
      categories.append(
        TimelineCategory(
          id: legacy.id, name: String(legacy.text.prefix(60)), colorHex: "#B984FF",
          details: legacy.text, order: editableCategories.count, targetEnabled: true))
      save()
    }
    defaults.set(true, forKey: migrationKey)
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(categories) {
      defaults.set(data, forKey: StoreKeys.categories)
      onEventsChanged(categories)
    }
  }

}

extension CategoryStore {
  nonisolated static func descriptorsForLLM() -> [LLMCategoryDescriptor] {
    let categories = CategoryPersistence.loadPersistedCategories()
    let effective = categories.isEmpty ? CategoryPersistence.defaultCategories : categories
    return
      effective
      .sorted { $0.order < $1.order }
      .map { category in
        LLMCategoryDescriptor(
          id: category.id,
          name: category.name,
          colorHex: category.colorHex,
          description: {
            if category.isIdle {
              return "Use when the user is idle for more than half of this period."
            }
            let trimmed = category.details.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
          }(),
          isSystem: category.isSystem,
          isIdle: category.isIdle
        )
      }
  }
}

enum CategoryPersistence {
  static func loadPersistedCategories(defaults: UserDefaults = AppStoragePaths.defaults) -> [TimelineCategory] {
    guard let data = defaults.data(forKey: CategoryStore.StoreKeys.categories) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let categories = try? decoder.decode([TimelineCategory].self, from: data) {
      return ensureIdleCategoryPresent(in: categories)
    }
    struct LegacyColorCategory: Codable {
      let id: Int64
      var name: String
      var color: String?
      var details: String
      var isNew: Bool?
    }
    if let legacy = try? decoder.decode([LegacyColorCategory].self, from: data) {
      var order = 0
      let converted = legacy.map { item -> TimelineCategory in
        defer { order += 1 }
        return TimelineCategory(
          id: UUID(),
          name: item.name,
          colorHex: item.color ?? "#E5E7EB",
          details: item.details,
          order: order,
          isSystem: false,
          isIdle: false,
          isNew: item.isNew ?? false
        )
      }
      return ensureIdleCategoryPresent(in: converted)
    }
    return []
  }

  static var defaultCategories: [TimelineCategory] {
    let now = Date()
    let base: [(String, String, Bool, Bool, String)] = [
      (
        "Work",
        "#B984FF",
        false,
        false,
        "Career, school, or productivity-focused activities (projects, emails, assignments, video calls, learning skills, etc.)"
      ),
      (
        "Personal",
        "#6AADFF",
        false,
        false,
        "Purposeful non-work activities or life tasks (paying bills, fitness tracking, meal planning, personal research, creative hobbies, etc.)"
      ),
      (
        "Distraction",
        "#FF5950",
        false,
        false,
        "Passive consumption or aimless browsing (scrolling feeds, watching random videos, clicking through news, mindless games, etc.)"
      ),
      (
        "Idle",
        "#A0AEC0",
        true,
        true,
        "For when the user is idle for most of the time."
      ),
    ]
    return base.enumerated().map { idx, entry in
      TimelineCategory(
        name: entry.0,
        colorHex: entry.1,
        details: entry.4,
        order: idx,
        isSystem: entry.2,
        isIdle: entry.3,
        isNew: false,
        createdAt: now,
        updatedAt: now
      )
    }
  }

  static func ensureIdleCategoryPresent(in categories: [TimelineCategory]) -> [TimelineCategory] {
    if categories.contains(where: { $0.isIdle }) {
      return categories.sorted { $0.order < $1.order }
    }

    var updated = categories
    let order = (categories.map { $0.order }.max() ?? -1) + 1
    let now = Date()
    let idle = TimelineCategory(
      name: "Idle",
      colorHex: "#A0AEC0",
      details: "Mark sessions where the user is idle for most of the time.",
      order: order,
      isSystem: true,
      isIdle: true,
      isNew: false,
      createdAt: now,
      updatedAt: now
    )
    updated.append(idle)
    return updated.sorted { $0.order < $1.order }
  }
}
