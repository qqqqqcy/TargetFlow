//
//  DaySummaryStats.swift
//  Dayflow
//
//  Pure stat computation for the "Your day so far" panel. Everything here is
//  parameter-driven and safe to call from a background task — DaySummaryView
//  invokes these off the main thread to avoid hangs during body evaluation.
//

import Foundation

enum DaySummaryStats {
  /// Pre-computed card data with parsed timestamps to avoid expensive parsing during body evaluation
  struct CardWithDuration {
    let card: TimelineCard
    let duration: TimeInterval
    let startMinutes: Int  // For focus blocks calculation
    let endMinutes: Int  // For focus blocks calculation
  }

  private static let focusGapMinutes: Int = 5
  private static let timelineDayStartMinutes: Int = 4 * 60
  private static let minutesPerDay: Int = 24 * 60

  private static func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func timelineMinutes(for timeString: String) -> Int? {
    guard let minutes = parseTimeHMMA(timeString: timeString) else { return nil }
    if minutes >= timelineDayStartMinutes {
      return minutes - timelineDayStartMinutes
    }
    return minutes + (minutesPerDay - timelineDayStartMinutes)
  }

  /// Pre-computes per-card durations clipped to the current timeline day window (4 AM -> 4 AM).
  /// Overlap normalization is applied later based on active category configuration.
  static func precomputeCardDurations(_ cards: [TimelineCard]) -> [CardWithDuration] {
    cards.compactMap { card in
      guard let startMinutes = timelineMinutes(for: card.startTimestamp),
        let endMinutes = timelineMinutes(for: card.endTimestamp)
      else {
        return nil
      }
      var adjustedEnd = endMinutes
      if adjustedEnd < startMinutes {
        adjustedEnd += minutesPerDay
      }

      // Clip to this timeline day's 24h window so cross-boundary cards only
      // contribute the portion that belongs to the selected day.
      let clippedStart = min(max(startMinutes, 0), minutesPerDay)
      let clippedEnd = min(max(adjustedEnd, 0), minutesPerDay)
      guard clippedEnd > clippedStart else { return nil }

      let duration = TimeInterval(clippedEnd - clippedStart) * 60
      return CardWithDuration(
        card: card,
        duration: duration,
        startMinutes: clippedStart,
        endMinutes: clippedEnd
      )
    }
  }

  /// Removes overlapping coverage by trimming later cards so each minute of the day is counted once.
  private static func removeOverlaps(from durations: [CardWithDuration]) -> [CardWithDuration] {
    guard durations.count > 1 else { return durations }

    let sorted = durations.sorted { lhs, rhs in
      if lhs.startMinutes == rhs.startMinutes {
        if lhs.endMinutes == rhs.endMinutes {
          let lhsId = lhs.card.recordId ?? 0
          let rhsId = rhs.card.recordId ?? 0
          return lhsId < rhsId
        }
        // Prefer the longer interval when starts match.
        return lhs.endMinutes > rhs.endMinutes
      }
      return lhs.startMinutes < rhs.startMinutes
    }

    var normalized: [CardWithDuration] = []
    normalized.reserveCapacity(sorted.count)
    var coveredUntil = 0

    for item in sorted {
      if coveredUntil >= minutesPerDay { break }

      let normalizedStart = max(item.startMinutes, coveredUntil)
      let normalizedEnd = min(item.endMinutes, minutesPerDay)
      guard normalizedEnd > normalizedStart else { continue }

      normalized.append(
        CardWithDuration(
          card: item.card,
          duration: TimeInterval(normalizedEnd - normalizedStart) * 60,
          startMinutes: normalizedStart,
          endMinutes: normalizedEnd
        )
      )
      coveredUntil = max(coveredUntil, normalizedEnd)
    }

    return normalized
  }

  private static func normalizedNonSystemDurations(
    from precomputed: [CardWithDuration], categories: [TimelineCategory]
  ) -> [CardWithDuration] {
    let nonSystemDurations = precomputed.filter { item in
      !isSystemCategoryStatic(item.card.category, categories: categories)
    }
    return removeOverlaps(from: nonSystemDurations)
  }

  /// Computes category durations from pre-computed data
  static func computeCategoryDurations(
    from precomputed: [CardWithDuration], categories: [TimelineCategory]
  ) -> [CategoryTimeData] {
    let categoryLookup = firstCategoryLookup(
      from: categories, normalizedKey: normalizedCategoryName)
    var durationsByCategory: [String: TimeInterval] = [:]
    var fallbackNamesByCategory: [String: String] = [:]

    for item in normalizedNonSystemDurations(from: precomputed, categories: categories) {
      let categoryKey = normalizedCategoryName(item.card.category)
      durationsByCategory[categoryKey, default: 0] += item.duration

      if fallbackNamesByCategory[categoryKey] == nil {
        fallbackNamesByCategory[categoryKey] = item.card.category
      }
    }

    return durationsByCategory.keys.sorted { lhs, rhs in
      let lhsDuration = durationsByCategory[lhs, default: 0]
      let rhsDuration = durationsByCategory[rhs, default: 0]
      let lhsDisplayMinutes = Int(lhsDuration / 60)
      let rhsDisplayMinutes = Int(rhsDuration / 60)

      if lhsDisplayMinutes != rhsDisplayMinutes {
        return lhsDisplayMinutes > rhsDisplayMinutes
      }

      let lhsOrder = categoryLookup[lhs]?.order ?? Int.max
      let rhsOrder = categoryLookup[rhs]?.order ?? Int.max

      if lhsOrder != rhsOrder {
        return lhsOrder < rhsOrder
      }

      let lhsName = categoryLookup[lhs]?.name ?? fallbackNamesByCategory[lhs] ?? lhs
      let rhsName = categoryLookup[rhs]?.name ?? fallbackNamesByCategory[rhs] ?? rhs
      return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
    }
    .compactMap { categoryKey -> CategoryTimeData? in
      guard let duration = durationsByCategory[categoryKey] else { return nil }
      guard duration > 0 else { return nil }

      if let category = categoryLookup[categoryKey] {
        return CategoryTimeData(category: category, duration: duration)
      }

      let name = fallbackNamesByCategory[categoryKey] ?? categoryKey
      return CategoryTimeData(name: name, colorHex: "#E5E7EB", duration: duration)
    }
  }

  /// Computes total captured time from pre-computed data
  static func computeTotalCapturedTime(
    from precomputed: [CardWithDuration], categories: [TimelineCategory]
  ) -> TimeInterval {
    normalizedNonSystemDurations(from: precomputed, categories: categories).reduce(0) {
      total, item in
      total + item.duration
    }
  }

  /// Computes total focus time from pre-computed data
  static func computeTotalFocusTime(
    from precomputed: [CardWithDuration], snapshots: [DayGoalCategorySnapshot],
    categories: [TimelineCategory]
  ) -> TimeInterval {
    normalizedNonSystemDurations(from: precomputed, categories: categories)
      .filter {
        isGoalCategoryStatic($0.card.category, snapshots: snapshots, categories: categories)
      }
      .reduce(0) { $0 + $1.duration }
  }

  /// Computes focus blocks from pre-computed data
  static func computeFocusBlocks(
    from precomputed: [CardWithDuration], snapshots: [DayGoalCategorySnapshot], baseDate: Date,
    categories: [TimelineCategory]
  ) -> [FocusBlock] {
    let focusCards = normalizedNonSystemDurations(from: precomputed, categories: categories)
      .filter {
        isGoalCategoryStatic($0.card.category, snapshots: snapshots, categories: categories)
      }

    var blocks: [(start: Int, end: Int)] = []
    for item in focusCards {
      blocks.append((start: item.startMinutes, end: item.endMinutes))
    }

    let sorted = blocks.sorted { $0.start < $1.start }
    var merged: [(start: Int, end: Int)] = []
    for block in sorted {
      if let last = merged.last {
        let gap = block.start - last.end
        if gap < focusGapMinutes {
          merged[merged.count - 1].end = max(last.end, block.end)
          continue
        }
      }
      merged.append(block)
    }

    return merged.map { block in
      let startDate = baseDate.addingTimeInterval(TimeInterval(block.start * 60))
      let endDate = baseDate.addingTimeInterval(TimeInterval(block.end * 60))
      return FocusBlock(startTime: startDate, endTime: endDate)
    }
  }

  /// Computes total distracted time from pre-computed data
  static func computeTotalDistractedTime(
    from precomputed: [CardWithDuration], snapshots: [DayGoalCategorySnapshot],
    categories: [TimelineCategory]
  ) -> TimeInterval {
    normalizedNonSystemDurations(from: precomputed, categories: categories).reduce(0) {
      total, item in
      guard
        isGoalCategoryStatic(item.card.category, snapshots: snapshots, categories: categories)
      else { return total }
      return total + item.duration
    }
  }

  /// Category matcher that treats the built-in "system" category (and any category
  /// flagged isSystem) as excluded from stats.
  private static func isSystemCategoryStatic(_ name: String, categories: [TimelineCategory])
    -> Bool
  {
    let normalized = normalizedCategoryName(name)
    if normalized == "system" { return true }
    guard let category = categories.first(where: { normalizedCategoryName($0.name) == normalized })
    else {
      return false
    }
    return category.isSystem
  }

  /// Goal-category matcher that prefers current category IDs and falls back to saved names.
  private static func isGoalCategoryStatic(
    _ name: String, snapshots: [DayGoalCategorySnapshot], categories: [TimelineCategory]
  ) -> Bool {
    if isSystemCategoryStatic(name, categories: categories) { return false }
    let normalized = normalizedCategoryName(name)
    let selectedIDs = Set(snapshots.map(\.categoryID))

    if let category = categories.first(where: { normalizedCategoryName($0.name) == normalized }),
      selectedIDs.contains(category.id.uuidString)
    {
      return true
    }

    return snapshots.contains { normalizedCategoryName($0.name) == normalized }
  }

  static func carriedForwardGoalPlan(
    day: String,
    storageManager: StorageManaging,
    categories: [TimelineCategory]
  ) -> DayGoalPlan {
    let saved = storageManager.fetchMostRecentDayGoalPlan(beforeOrOn: day)
    let plan = saved ?? DayGoalPlan.defaultPlan(day: day, categories: categories)
    return plan.carriedForward(to: day, categories: categories)
  }

}
