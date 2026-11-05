import Foundation

/// Settings and event switches can change while the model is running. Reapply
/// the local boundary plan to each trusted run immediately before committing;
/// never split a newly enlarged window into unreachable pending fragments.
enum TimelineStabilizedCommit {
  static func cards(_ cards: [ActivityCardData], nearest: Int, minimum: Int) throws -> [ActivityCardData] {
    var runs: [[ActivityCardData]] = []
    for card in cards {
      if let last = runs.last?.last, last.sourceScreenshotIDs == card.sourceScreenshotIDs {
        runs[runs.count - 1].append(card)
      } else { runs.append([card]) }
    }
    return try runs.flatMap { run in
      let plan = try TimelineStabilizationPolicy.plan(run, nearest: nearest, minimum: minimum)
      if try TimelineStabilizationPolicy.matches(run, plan: plan, nearest: nearest) { return run }
      return TimelineStabilizationPolicy.fallback(run, plan: plan).map { card in
        var copy = card
        copy.sourceScreenshotIDs = run.first?.sourceScreenshotIDs
        return copy
      }
    }
  }
}
