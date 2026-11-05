import Foundation

/// A deterministic category/boundary plan, not a prose merger. Call separately for
/// each proven capture run. Gaps, 4 AM, and 60-minute segments remain hard boundaries.
enum TimelineStabilizationPolicy {
  struct Group: Equatable {
    var range: Range<Int>
    var category: String
    var sourceIndices: [Int]
  }

  static func key(_ category: String) -> String {
    TimelineEventDisplay.canonicalCategoryKey(category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  static func plan(_ cards: [ActivityCardData], nearest anchor: Int,
    minimum: Int = Int(AnalysisPreferences.interval)) throws -> [Group] {
    let ranges = try cards.map { try ClaudeOutputValidator.resolveActivityCardInterval($0, nearest: anchor) }
    var runs: [Range<Int>] = []
    for range in ranges {
      if let last = runs.last, last.upperBound == range.lowerBound,
        Date(timeIntervalSince1970: Double(last.lowerBound)).getDayInfoFor4AMBoundary().dayString
          == Date(timeIntervalSince1970: Double(range.lowerBound)).getDayInfoFor4AMBoundary().dayString {
        runs[runs.count - 1] = last.lowerBound..<range.upperBound
      } else { runs.append(range) }
    }
    var result: [Group] = []
    for run in runs {
      var start = run.lowerBound
      while start < run.upperBound {
        let dayEnd = Int(Date(timeIntervalSince1970: Double(start)).getDayInfoFor4AMBoundary().endOfDay.timeIntervalSince1970)
        var end = min(run.upperBound, start + 3600, dayEnd)
        // Avoid creating a pending tail solely because of the maximum-card limit.
        if end < run.upperBound, run.upperBound - end < minimum, end != dayEnd {
          end -= minimum - (run.upperBound - end)
        }
        let segment = start..<end
        var blocks: [Group] = []
        for index in cards.indices where ranges[index].overlaps(segment) {
          let clipped = max(start, ranges[index].lowerBound)..<min(end, ranges[index].upperBound)
          if let last = blocks.last, key(last.category) == key(cards[index].category) {
            blocks[blocks.count - 1].range = last.range.lowerBound..<clipped.upperBound
            blocks[blocks.count - 1].sourceIndices.append(index)
          } else { blocks.append(Group(range: clipped, category: cards[index].category, sourceIndices: [index])) }
        }
        let stable = blocks.indices.filter { blocks[$0].range.count >= minimum }
        if stable.isEmpty {
          // No sustained label: use successive stability windows, including a
          // trailing partial window in the last full one. Never vote over an
          // arbitrary hour, and never leave individually short switches pending.
          var windowStart = start
          var voted: [Group] = []
          while windowStart < end {
            var windowEnd = min(end, windowStart + minimum)
            if end - windowEnd < minimum { windowEnd = end }
            let window = windowStart..<windowEnd
            let covered = blocks.filter { $0.range.overlaps(window) }
            var totals: [String: Int] = [:]
            for block in covered {
              totals[key(block.category), default: 0] += min(windowEnd, block.range.upperBound) - max(windowStart, block.range.lowerBound)
            }
            // Strict comparison preserves the earlier category on a tie.
            let winner = covered.dropFirst().reduce(covered[0]) { best, next in
              totals[key(next.category), default: 0] > totals[key(best.category), default: 0] ? next : best
            }
            let sources = covered.flatMap(\.sourceIndices)
            if let last = voted.last, key(last.category) == key(winner.category) {
              voted[voted.count - 1].range = last.range.lowerBound..<windowEnd
              voted[voted.count - 1].sourceIndices = Array(Set(last.sourceIndices + sources)).sorted()
            } else { voted.append(Group(range: window, category: winner.category, sourceIndices: sources)) }
            windowStart = windowEnd
          }
          result += voted
        } else {
          for index in blocks.indices where !stable.contains(index) {
            let short = blocks[index].range
            // Compare the adjacent stability windows by time, never by card count.
            // Ties go to the earlier stable event. Stable A and C are never relabeled.
            let candidates = stable.filter { blocks[$0].range.upperBound > short.lowerBound - minimum
              && blocks[$0].range.lowerBound < short.upperBound + minimum }
            let neighbors = candidates.isEmpty ? stable : candidates
            let winner = neighbors.max { left, right in
              func score(_ i: Int) -> Int {
                max(0, min(blocks[i].range.upperBound, short.upperBound + minimum)
                  - max(blocks[i].range.lowerBound, short.lowerBound - minimum))
              }
              return score(left) == score(right) ? left > right : score(left) < score(right)
            }!
            blocks[index].category = blocks[winner].category
          }
          var merged: [Group] = []
          for block in blocks {
            if let last = merged.last, key(last.category) == key(block.category) {
              merged[merged.count - 1].range = last.range.lowerBound..<block.range.upperBound
              merged[merged.count - 1].sourceIndices += block.sourceIndices
            } else { merged.append(block) }
          }
          result += merged
        }
        start = end
      }
    }
    return result
  }

  static func matches(_ cards: [ActivityCardData], plan: [Group], nearest anchor: Int) throws -> Bool {
    guard cards.count == plan.count else { return false }
    return try zip(cards, plan).allSatisfy {
      try ClaudeOutputValidator.resolveActivityCardInterval($0.0, nearest: anchor) == $0.1.range
        && key($0.0.category) == key($0.1.category)
    }
  }

  /// Bounded failure recovery: reuse a dominant provider-authored title/summary,
  /// not locally invented prose. All source facts stay in timestamped details.
  static func fallback(_ cards: [ActivityCardData], plan: [Group]) -> [ActivityCardData] {
    let clock = TimelineOutputPolicy()
    return plan.map { group in
      let sources = group.sourceIndices.map { cards[$0] }
      let representative = sources.first { key($0.category) == key(group.category) } ?? sources[0]
      let details: String = sources.map { card -> String in
        let sites = [card.appSites?.primary, card.appSites?.secondary].compactMap { $0 }.joined(separator: ", ")
        let interruptions = (card.distractions ?? []).map { "\($0.startTime) - \($0.endTime): \($0.title) — \($0.summary)" }.joined(separator: "\n")
        return "\(card.startTime) - \(card.endTime): \(card.title) — \(card.summary)\n\(card.detailedSummary)\n\(sites)\n\(interruptions)"
      }.joined(separator: "\n")
      return ActivityCardData(startTime: clock.formatTimestampForPrompt(group.range.lowerBound),
        endTime: clock.formatTimestampForPrompt(group.range.upperBound), category: group.category,
        subcategory: representative.subcategory, title: representative.title, summary: representative.summary,
        detailedSummary: details, distractions: nil, appSites: representative.appSites, evidenceKind: .visible)
    }
  }
}
