import Foundation

/// Event switches affect new classifications, never the labels of published history.
struct TimelineCategoryWritePolicy {
  let descriptors: [LLMCategoryDescriptor]
  private let enabledKeys: Set<String>

  init(categories: [TimelineCategory]) {
    descriptors = CategoryStore.descriptorsForLLM(categories: categories)
    enabledKeys = Set(descriptors.map { TimelineEventDisplay.canonicalCategoryKey($0.name) })
  }

  static func current() -> Self {
    let saved = CategoryPersistence.loadPersistedCategories()
    return Self(categories: saved.isEmpty ? CategoryPersistence.defaultCategories : saved)
  }

  func isDisabled(_ label: String) -> Bool {
    guard label != "System", !TimelineEventDisplay.isReserved(label),
      !TimelineEventDisplay.isPlaceholderName(label) else { return false }
    // A renamed or deleted definition leaves its original name on historical
    // cards. Protect those retired labels just like explicitly disabled labels.
    return !enabledKeys.contains(TimelineEventDisplay.canonicalCategoryKey(label))
  }

  static func sameHistoricalCategory(_ lhs: String, _ rhs: String) -> Bool {
    TimelineEventDisplay.canonicalCategoryKey(lhs) == TimelineEventDisplay.canonicalCategoryKey(rhs)
  }

  /// Conservatively exclude all lookback through the latest protected record. This
  /// also prevents an enabled card before that record from extending a rewrite over it.
  func protectedHistoryEnd(_ history: [TimelineCard]) -> Int? {
    history.filter { isDisabled($0.category) }.compactMap(\.endTs).max()
  }

  func cardsForCommit(
    _ cards: [ActivityCardData], history: [TimelineCard], nearest: Int
  ) throws -> [ActivityCardData] {
    let protectedEnd = protectedHistoryEnd(history)
    let output = TimelineOutputPolicy()
    return try cards.compactMap { original in
      var startTime = original.startTime
      if let protectedEnd {
        let range = try ClaudeOutputValidator.resolveActivityCardInterval(original, nearest: nearest)
        // Model clocks have minute precision. Round forward, never into protected history.
        let firstWritableMinute = (protectedEnd + 59) / 60 * 60
        guard range.upperBound > firstWritableMinute else { return nil }
        if range.lowerBound < firstWritableMinute {
          startTime = output.formatTimestampForPrompt(firstWritableMinute)
        }
      }
      var card = ActivityCardData(
        startTime: startTime, endTime: original.endTime,
        category: original.category == "System" ? "System"
          : output.normalizeCategory(original.category, descriptors: descriptors),
        subcategory: original.subcategory, title: original.title, summary: original.summary,
        detailedSummary: original.detailedSummary, distractions: original.distractions,
        appSites: original.appSites, evidenceKind: original.evidenceKind)
      card.sourceScreenshotIDs = original.sourceScreenshotIDs
      return card
    }
  }
}
