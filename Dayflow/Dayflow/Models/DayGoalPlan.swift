import Foundation

enum DayGoalCategoryKind: String, CaseIterable, Sendable {
  case focus
  case distraction
}

struct DayGoalCategorySnapshot: Identifiable, Equatable, Sendable {
  let categoryID: String
  var name: String
  var colorHex: String
  var sortOrder: Int

  var id: String {
    categoryID
  }

  init(categoryID: String, name: String, colorHex: String, sortOrder: Int) {
    self.categoryID = categoryID
    self.name = name
    self.colorHex = colorHex
    self.sortOrder = sortOrder
  }

  init(category: TimelineCategory, sortOrder: Int) {
    self.categoryID = category.id.uuidString
    self.name = category.name
    self.colorHex = category.colorHex
    self.sortOrder = sortOrder
  }
}

struct DayGoalPlan: Equatable, Sendable {
  var day: String
  var focusTargetMinutes: Int
  var distractionLimitMinutes: Int
  var focusCategories: [DayGoalCategorySnapshot]
  var distractionCategories: [DayGoalCategorySnapshot]
  var isSkipped: Bool
  var createdAt: Int
  var updatedAt: Int

  func forDay(_ day: String) -> DayGoalPlan {
    var copy = self
    if copy.day != day {
      copy.isSkipped = false
      copy.createdAt = 0
      copy.updatedAt = 0
    }
    copy.day = day
    return copy
  }

  func carriedForward(to day: String, categories: [TimelineCategory]) -> DayGoalPlan {
    var copy = forDay(day)
    copy.focusCategories = Self.resolvedSnapshots(
      copy.focusCategories,
      categories: categories
    )
    copy.distractionCategories = Self.resolvedSnapshots(
      copy.distractionCategories,
      categories: categories
    )
    return copy
  }

  static func defaultPlan(day: String, categories: [TimelineCategory]) -> DayGoalPlan {
    let now = Int(Date().timeIntervalSince1970)
    let selectable =
      categories
      .filter { $0.isSystem == false && $0.isIdle == false }
      .sorted { $0.order < $1.order }

    let focusCandidates = selectable.filter(\.isCurrentTarget)
    let distraction = selectable.filter { !$0.isCurrentTarget }

    return DayGoalPlan(
      day: day,
      focusTargetMinutes: 270,
      distractionLimitMinutes: 120,
      focusCategories: focusCandidates.enumerated().map { index, category in
        DayGoalCategorySnapshot(category: category, sortOrder: index)
      },
      distractionCategories: distraction.enumerated().map { index, category in
        DayGoalCategorySnapshot(category: category, sortOrder: index)
      },
      isSkipped: false,
      createdAt: now,
      updatedAt: now
    )
  }

  private static func resolvedSnapshots(
    _ snapshots: [DayGoalCategorySnapshot],
    categories: [TimelineCategory]
  ) -> [DayGoalCategorySnapshot] {
    let selectable = categories.filter { $0.isSystem == false && $0.isIdle == false }
    let categoryByID = Dictionary(uniqueKeysWithValues: selectable.map { ($0.id.uuidString, $0) })
    let categoryByName = firstCategoryLookup(
      from: selectable, normalizedKey: normalizedCategoryName)

    return snapshots.map { snapshot in
      let current =
        categoryByID[snapshot.categoryID]
        ?? categoryByName[normalizedCategoryName(snapshot.name)]
      guard let current else { return snapshot }

      return DayGoalCategorySnapshot(
        categoryID: current.id.uuidString,
        name: current.name,
        colorHex: current.colorHex,
        sortOrder: snapshot.sortOrder
      )
    }
  }

  private static func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
