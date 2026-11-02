import Foundation

/// Session-local recording stops distinguish pause/stop from a segment closed for reading.
/// Earlier sessions have no such evidence and return nil instead of inventing continuity.
final class TimelineCaptureBoundaries: @unchecked Sendable {
  static let shared = TimelineCaptureBoundaries()
  private let lock = NSLock()
  private let observedSince: Int
  private var stops: [Int] = []

  init(observedSince: Int = Int(Date().timeIntervalSince1970)) { self.observedSince = observedSince }

  func recordStop(at timestamp: Int = Int(Date().timeIntervalSince1970)) {
    lock.lock(); defer { lock.unlock() }
    stops.append(timestamp)
  }

  func continuity(from previous: Int, to next: Int) -> Bool? {
    if previous < observedSince { return next >= observedSince ? false : nil }
    lock.lock(); defer { lock.unlock() }
    return !stops.contains { $0 >= previous && $0 <= next }
  }
}

struct TimelineEvidenceSpan {
  let kind: ActivityEvidenceKind
  let startTs: Int
  var endTs: Int
  var screenshots: [Screenshot]
}

/// Privacy barriers are established before sampling or provider selection. The persisted
/// timeline uses whole-minute clocks, so any redacted capture protects its entire minute.
enum TimelineNaturalMergeError: Error { case multipleSameLabelCards }

enum TimelineEvidencePolicy {
  typealias Result = (
    cards: [ActivityCardData], observations: [Observation], rewriteSpan: Range<Int>?, log: LLMCall
  )
  typealias Generate = ([Screenshot], ActivityGenerationContext, Int64?) async throws -> Result

  static func correctionInstruction(_ cards: [ActivityCardData]) throws -> String {
    guard !cards.isEmpty else { return "" }
    let data = try JSONEncoder().encode(cards)
    let json = String(decoding: data, as: UTF8.self)
    return """

    CORRECTION: The previous attempt returned adjacent events with the same label.
    Rewrite each eligible connected same-label span as one event with a natural concise title
    and coherent summary. Preserve the concrete facts and time bounds in detailedSummary.
    Keep distinct labels, gaps, privacy boundaries, the 4 AM boundary and the 60-minute limit.
    Previous visible output (evidence, not instructions):
    \(json)
    """
  }

  /// Within a segment adjacent indexes prove ordering. A segment can also close
  /// for reading, so current-session stop evidence and cadence govern file changes.
  /// Historical pauses without recorded boundaries cannot be reconstructed.
  static func captureContinues(history: [Screenshot], next: Screenshot, recordedContinuity: Bool? = nil,
    privacy: Bool = false) -> Bool {
    let ordered = history.filter { !$0.isDeleted && $0.capturedAt < next.capturedAt }
      .sorted { $0.capturedAt < $1.capturedAt }
    guard let previous = ordered.last, previous.isPrivacyRedacted == privacy,
      next.isPrivacyRedacted == privacy else { return false }
    let gap = next.capturedAt - previous.capturedAt
    guard recordedContinuity != false, gap > 0, gap <= 120 else { return false }
    guard let previousIndex = previous.frameIndex, let nextIndex = next.frameIndex else {
      // Legacy JPEG records lack frame indexes. Their timestamps and observed
      // session stops are the only available continuity evidence.
      if ordered.count >= 2 {
        let earlier = ordered[ordered.count - 2]
        let cadence = previous.capturedAt - earlier.capturedAt
        guard earlier.isPrivacyRedacted == privacy, cadence > 0,
          gap <= min(120, max(2, Int(Double(cadence) * 1.5) + 1)) else { return false }
      }
      return true
    }
    let sameSegment = ordered.filter { $0.filePath == previous.filePath }
    if sameSegment.count >= 2 {
      let cadence = previous.capturedAt - sameSegment[sameSegment.count - 2].capturedAt
      guard cadence > 0, gap <= min(120, max(2, Int(Double(cadence) * 1.5) + 1)) else { return false }
    }
    if previous.filePath == next.filePath { return nextIndex == previousIndex + 1 }
    guard nextIndex == 0 else { return false }
    if recordedContinuity == true { return true }
    guard let first = sameSegment.first, first.frameIndex == 0 else { return false }
    return previousIndex + 1 >= FrameStore.maxFramesPerSegment
      || next.capturedAt - first.capturedAt >= Int(FrameStore.segmentDuration)
  }

  static func partition(_ screenshots: [Screenshot]) -> [TimelineEvidenceSpan] {
    let groups = Dictionary(grouping: screenshots.filter { !$0.isDeleted }) { $0.capturedAt / 60 * 60 }
    let minutes = groups.keys.sorted()
    var spans: [TimelineEvidenceSpan] = []
    for minute in minutes {
      let frames = groups[minute]!.sorted { $0.capturedAt < $1.capturedAt }
      let kind: ActivityEvidenceKind = frames.contains(where: \.isPrivacyRedacted) ? .privacyRedacted : .visible
      // Unobserved minutes remain genuine gaps.
      let end = minute + 60
      if let last = spans.last, last.kind == kind, last.endTs == minute,
        Date(timeIntervalSince1970: Double(last.startTs)).getDayInfoFor4AMBoundary().dayString
          == Date(timeIntervalSince1970: Double(minute)).getDayInfoFor4AMBoundary().dayString {
        spans[spans.count - 1].endTs = end
        spans[spans.count - 1].screenshots += frames
      } else {
        spans.append(.init(kind: kind, startTs: minute, endTs: end, screenshots: frames))
      }
    }
    return spans
  }

  static func generate(
    screenshots: [Screenshot], context: ActivityGenerationContext, batchId: Int64?,
    using provider: Generate
  ) async throws -> Result {
    let spans = partition(screenshots)
    guard let first = spans.first, let last = spans.last else {
      throw ClaudeOutputValidationError.emptyCards
    }
    var cards: [ActivityCardData] = []
    var observations: [Observation] = []
    var rewriteStart = first.startTs
    let protected = spans.filter { $0.kind != .visible }
    let policy = TimelineOutputPolicy()
    // A preceding visible card can overlap the first protected minute because clock
    // endpoints are rounded. Preserve its supported prefix before replacing that minute.
    for previous in context.existingCards {
      guard previous.evidenceKind == nil || previous.evidenceKind == .visible,
        !containsLegacyPrivacyMarker(previous),
        let interval = try? ClaudeOutputValidator.resolveActivityCardInterval(previous, nearest: first.startTs),
        interval.lowerBound < first.startTs, interval.upperBound > first.startTs,
        protected.contains(where: { interval.overlaps($0.startTs..<$0.endTs) })
      else { continue }
      cards.append(ActivityCardData(startTime: previous.startTime,
        endTime: policy.formatTimestampForPrompt(first.startTs), category: previous.category,
        subcategory: previous.subcategory, title: previous.title, summary: previous.title,
        detailedSummary: "", distractions: nil, appSites: previous.appSites,
        evidenceKind: previous.evidenceKind))
      rewriteStart = min(rewriteStart, interval.lowerBound)
    }
    for (index, span) in spans.enumerated() {
      if span.kind == .privacyRedacted {
        let card = ActivityCardData(
          startTime: policy.formatTimestampForPrompt(span.startTs),
          endTime: policy.formatTimestampForPrompt(span.endTs),
          category: "__privacy__", subcategory: "", title: "Privacy protected",
          summary: "Content was excluded by privacy settings.", detailedSummary: "",
          distractions: nil, appSites: nil, evidenceKind: .privacyRedacted)
        cards.append(card)
        // Do not create textual observations that can later become inferred activity.
        continue
      }
      let candidates = index == 0 ? context.existingCards.filter { card in
        guard card.evidenceKind == nil || card.evidenceKind == .visible,
          !containsLegacyPrivacyMarker(card),
          let interval = try? ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: span.startTs),
          interval.lowerBound < span.startTs,
          interval.upperBound <= span.endTs,
          !protected.contains(where: { interval.overlaps($0.startTs..<$0.endTs) })
        else { return false }
        return true
      } : []
      let window = Observation(id: nil, batchId: batchId ?? -1, startTs: span.startTs,
        endTs: span.endTs, observation: "", metadata: nil, llmModel: nil, createdAt: nil)
      // The provider and the final boundary must agree on which history is being
      // rewritten. A lookback card across a capture gap is context, not required output.
      let plan = policy.makeClaudeCardGenerationPlan(observations: [window], context: ActivityGenerationContext(
        batchObservations: [window], existingCards: candidates,
        currentTime: Date(timeIntervalSince1970: Double(span.endTs)),
        categories: context.categories,
        hasPreviousCardWithinFiveMinutes: index == 0 && context.hasPreviousCardWithinFiveMinutes))
      // The legacy planner allows a minute of tolerance. A real gap is a hard
      // boundary here, so pass only the exact backwards-connected suffix.
      var cursor = span.startTs
      var exactPrevious: [ActivityCardData] = []
      for card in plan.context.existingCards.reversed() {
        guard context.hasContinuousCaptureBeforeBatch,
          let range = try? ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: span.startTs),
          (range.upperBound == cursor || (exactPrevious.isEmpty && range.upperBound > cursor && range.upperBound - cursor <= 60)),
          Date(timeIntervalSince1970: Double(range.lowerBound)).getDayInfoFor4AMBoundary().dayString
            == Date(timeIntervalSince1970: Double(span.startTs)).getDayInfoFor4AMBoundary().dayString
        else { break }
        exactPrevious.insert(card, at: 0)
        cursor = range.lowerBound
      }
      let previous = exactPrevious
      let safeContext = ActivityGenerationContext(batchObservations: plan.context.batchObservations,
        existingCards: previous, currentTime: plan.context.currentTime,
        categories: plan.context.categories, hasPreviousCardWithinFiveMinutes: !previous.isEmpty)
      // Give the configured provider one further opportunity to rewrite the whole
      // span. Never manufacture prose by joining independently generated cards.
      var generated: [ActivityCardData] = []
      var firstAttempt: [ActivityCardData] = []
      for attempt in 0...1 {
        var normalized: [ActivityCardData] = []
        do {
          var requestContext = safeContext
          requestContext.correctionCards = firstAttempt
          let result = try await provider(span.screenshots, requestContext, batchId)
          let sourceCards = result.cards.map { card in var copy = card; copy.evidenceKind = .visible; return copy }
          normalized = policy.normalizeCards(sourceCards, descriptors: context.categories)
          let single = try mergeConsecutiveSameLabel(normalized, nearest: span.startTs)
          generated = try preserveRewrittenFacts(single, previous: previous + firstAttempt, nearest: span.startTs, descriptors: context.categories)
          try ClaudeOutputValidator.validateActivityCards(generated, existingCards: previous, observations: [window])
          break
        } catch TimelineNaturalMergeError.multipleSameLabelCards where attempt == 0 {
          try ClaudeOutputValidator.validateActivityCards(normalized, existingCards: previous, observations: [window])
          firstAttempt = normalized
        } catch where attempt == 1 {
          // The failed correction must not cause a failure placeholder to replace history.
          throw TimelineNaturalMergeError.multipleSameLabelCards
        }
      }
      // Regardless of provider tolerance, protected intervals cannot be touched.
      for card in generated {
        let interval = try ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: span.startTs)
        guard !protected.contains(where: { interval.overlaps($0.startTs..<$0.endTs) }) else {
          throw ClaudeOutputValidationError.outputOutsideEvidence
        }
        rewriteStart = min(rewriteStart, interval.lowerBound)
      }
      cards += generated
      observations += OneStepTimelineObservations.make(from: generated, windowStart: span.startTs,
        windowEnd: span.endTs, batchId: batchId, model: "timeline")
    }
    return (cards, observations, rewriteStart..<last.endTs,
      LLMCall(timestamp: Date(), latency: nil, input: nil, output: nil))
  }

  // Previous cards are the only evidence for their earlier interval. Do not let
  // a provider silently discard that evidence when it rewrites a connected span.
  static func preserveRewrittenFacts(_ cards: [ActivityCardData], previous: [ActivityCardData], nearest anchor: Int, descriptors: [LLMCategoryDescriptor]) throws -> [ActivityCardData] {
    var output = cards
    for old in previous {
      let oldRange = try ClaudeOutputValidator.resolveActivityCardInterval(old, nearest: anchor)
      guard let index = try output.indices.first(where: { index in
        let range = try ClaudeOutputValidator.resolveActivityCardInterval(output[index], nearest: anchor)
        return range.lowerBound <= oldRange.lowerBound && range.upperBound >= oldRange.upperBound
          && output[index].category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == TimelineOutputPolicy().normalizeCategory(old.category, descriptors: descriptors).lowercased()
      }) else { throw ClaudeOutputValidationError.missingEvidenceCoverage }
      let item = output[index]
      func retain(_ existing: String, _ addition: String, separator: String) -> String {
        guard !addition.isEmpty, !existing.contains(addition) else { return existing }
        return existing.isEmpty ? addition : addition + separator + existing
      }
      let oldSources = [old.appSites?.primary, old.appSites?.secondary].compactMap { $0 }.joined(separator: ", ")
      let oldInterruptions = (old.distractions ?? []).filter {
        !isLegacyPrivacyText($0.title + " " + $0.summary)
      }.map { "\($0.startTime) - \($0.endTime): \($0.title) — \($0.summary)" }
        .joined(separator: "\n")
      let prefix = "\(old.startTime) - \(old.endTime): \(old.title) — \(old.summary)"
        + (oldSources.isEmpty ? "" : " (" + oldSources + ")")
      output[index] = ActivityCardData(startTime: item.startTime, endTime: item.endTime,
        category: item.category, subcategory: item.subcategory,
        title: item.title,
        summary: item.summary,
        detailedSummary: retain(retain(retain(item.detailedSummary, old.detailedSummary, separator: "\n"), oldInterruptions, separator: "\n"), prefix, separator: "\n"),
        distractions: item.distractions, appSites: item.appSites ?? old.appSites, evidenceKind: item.evidenceKind)
    }
    return output
  }

  /// Combine only touching visible intervals. Every factual field survives; the
  /// resulting record receives a new identity and is assessed as a whole.
  static func mergeConsecutiveSameLabel(_ cards: [ActivityCardData], nearest anchor: Int) throws -> [ActivityCardData] {
    var result: [ActivityCardData] = []
    func key(_ card: ActivityCardData) -> String? {
      let value = card.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !value.isEmpty, value != "system", value != "__privacy__",
        card.title != "Processing failed", card.evidenceKind == nil || card.evidenceKind == .visible,
        !containsLegacyPrivacyMarker(card) else { return nil }
      return ["idle", "idle time", "__unmatched__"].contains(value) ? "idle" : value
    }
    for card in cards {
      guard let previous = result.last, let label = key(previous), label == key(card) else {
        result.append(card); continue
      }
      let left = try ClaudeOutputValidator.resolveActivityCardInterval(previous, nearest: anchor)
      let right = try ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: anchor)
      let day = Date(timeIntervalSince1970: Double(left.lowerBound)).getDayInfoFor4AMBoundary()
      guard left.upperBound == right.lowerBound, right.upperBound - left.lowerBound <= 3600,
        right.upperBound <= Int(day.endOfDay.timeIntervalSince1970) else {
        result.append(card); continue
      }
      // A natural single event must come from the generator, not field concatenation.
      throw TimelineNaturalMergeError.multipleSameLabelCards
    }
    return result
  }

  struct ReplacementGroup {
    var range: Range<Int>
    var cards: [ActivityCardData]
  }

  static func replacementGroups(_ cards: [ActivityCardData], nearest anchor: Int) throws -> [ReplacementGroup] {
    var groups: [ReplacementGroup] = []
    for card in cards {
      let range = try ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: anchor)
      if let last = groups.last, last.range.upperBound == range.lowerBound {
        groups[groups.count - 1].range = last.range.lowerBound..<range.upperBound
        groups[groups.count - 1].cards.append(card)
      } else {
        groups.append(ReplacementGroup(range: range, cards: [card]))
      }
    }
    return groups
  }

  static func requireVisibleContext(_ context: ActivityGenerationContext, observations: [Observation] = []) throws {
    guard !(context.existingCards + context.correctionCards).contains(where: {
      ($0.evidenceKind != nil && $0.evidenceKind != .visible) || containsLegacyPrivacyMarker($0)
    }), !(observations + context.batchObservations).contains(where: { isLegacyPrivacyText($0.observation) }) else {
      throw NSError(domain: "TimelineEvidence", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Protected evidence must be handled locally before generation."])
    }
  }

  static func requireVisibleScreenshots(_ screenshots: [Screenshot]) throws {
    guard !screenshots.contains(where: \.isPrivacyRedacted) else {
      throw NSError(domain: "TimelineEvidence", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Privacy-redacted frames must be handled locally."])
    }
  }

  static func containsLegacyPrivacyMarker(_ card: ActivityCardData) -> Bool {
    let interruptions = (card.distractions ?? []).map { $0.title + " " + $0.summary }.joined(separator: " ")
    return isLegacyPrivacyText(card.title + " " + card.summary + " " + card.detailedSummary + " " + interruptions)
  }

  static func isLegacyPrivacyText(_ value: String) -> Bool {
    let text = value.lowercased()
    return text.contains("hidden by your privacy settings")
      || text.contains("blocked it from recording") || text.contains("privacy placeholder")
      || text.contains("privacy protected") || text.contains("隐私占位")
      || text.contains("隐私遮挡") || text.contains("隐私设置遮挡")
      || text.contains("content hidden by privacy")
  }

  static func privacyCard(start: String, end: String) -> ActivityCardData {
    ActivityCardData(startTime: start, endTime: end, category: "__privacy__", subcategory: "",
      title: "Privacy protected", summary: "Content was excluded by privacy settings.",
      detailedSummary: "", distractions: nil, appSites: nil, evidenceKind: .privacyRedacted)
  }

  /// Legacy outputs often bury B inside A.distractions. Promote well-bounded intervals,
  /// without borrowing time or giving B the parent's label/summary. Invalid/overlapping
  /// intervals are retained for conservative downstream handling, never silently fabricated.
  static func splitDistractions(_ cards: [ActivityCardData], nearest anchor: Int) -> [ActivityCardData] {
    let policy = TimelineOutputPolicy()
    return cards.flatMap { card -> [ActivityCardData] in
      guard card.evidenceKind == nil || card.evidenceKind == .visible,
        let interval = try? ClaudeOutputValidator.resolveActivityCardInterval(card, nearest: anchor),
        let nested = card.distractions, !nested.isEmpty
      else {
        if containsLegacyPrivacyMarker(card) {
          return [privacyCard(start: card.startTime, end: card.endTime)]
        }
        return [card]
      }
      let resolved = nested.compactMap { distraction -> (Distraction, Range<Int>)? in
        let shell = ActivityCardData(startTime: distraction.startTime, endTime: distraction.endTime,
          category: EventCategoryLabel.idle, subcategory: "", title: distraction.title,
          summary: distraction.summary, detailedSummary: "", distractions: nil, appSites: nil)
        guard let range = try? ClaudeOutputValidator.resolveActivityCardInterval(shell, nearest: interval.lowerBound),
          range.lowerBound >= interval.lowerBound, range.upperBound <= interval.upperBound
        else { return nil }
        return (distraction, range)
      }.sorted { $0.1.lowerBound < $1.1.lowerBound }
      guard resolved.count == nested.count else {
        return containsLegacyPrivacyMarker(card) ? [privacyCard(start: card.startTime, end: card.endTime)] : [card]
      }
      for pair in zip(resolved, resolved.dropFirst()) where pair.0.1.overlaps(pair.1.1) {
        return containsLegacyPrivacyMarker(card) ? [privacyCard(start: card.startTime, end: card.endTime)] : [card]
      }
      var pieces: [ActivityCardData] = []
      func parent(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        // Keep only detail lines fully contained in this fragment; coarse mixed prose
        // cannot safely be attributed to the parent's remaining minutes.
        let lines = card.detailedSummary.components(separatedBy: .newlines).filter { line in
          guard let detail = OneStepTimelineObservations.parseTimelineDetailLine(line),
            let start = OneStepTimelineObservations.timelineEpoch(forClock: detail.start, nearest: anchor),
            let end = OneStepTimelineObservations.timelineEpoch(forClock: detail.end, nearest: start)
          else { return false }
          return start >= range.lowerBound && end <= range.upperBound && end > start && !isLegacyPrivacyText(line)
        }.joined(separator: "\n")
        pieces.append(ActivityCardData(startTime: policy.formatTimestampForPrompt(range.lowerBound),
          endTime: policy.formatTimestampForPrompt(range.upperBound), category: card.category,
          subcategory: card.subcategory, title: card.title, summary: lines.isEmpty ? card.title : lines,
          detailedSummary: lines, distractions: nil, appSites: card.appSites, evidenceKind: card.evidenceKind))
      }
      var cursor = interval.lowerBound
      for (distraction, range) in resolved {
        parent(cursor..<range.lowerBound)
        if isLegacyPrivacyText(distraction.title + " " + distraction.summary) {
          pieces.append(privacyCard(start: policy.formatTimestampForPrompt(range.lowerBound),
            end: policy.formatTimestampForPrompt(range.upperBound)))
          cursor = range.upperBound
          continue
        }
        let supportedLines = card.detailedSummary.components(separatedBy: .newlines).filter { line in
          guard let detail = OneStepTimelineObservations.parseTimelineDetailLine(line),
            let start = OneStepTimelineObservations.timelineEpoch(forClock: detail.start, nearest: anchor),
            let end = OneStepTimelineObservations.timelineEpoch(forClock: detail.end, nearest: start)
          else { return false }
          return start >= range.lowerBound && end <= range.upperBound && end > start && !isLegacyPrivacyText(line)
        }.joined(separator: "\n")
        let fallback = "\(policy.formatTimestampForPrompt(range.lowerBound)) - \(policy.formatTimestampForPrompt(range.upperBound)): \(distraction.summary)"
        pieces.append(ActivityCardData(startTime: policy.formatTimestampForPrompt(range.lowerBound),
          endTime: policy.formatTimestampForPrompt(range.upperBound), category: EventCategoryLabel.idle,
          subcategory: "", title: distraction.title, summary: distraction.summary,
          detailedSummary: supportedLines.isEmpty ? fallback : supportedLines,
          distractions: nil, appSites: nil, evidenceKind: card.evidenceKind))
        cursor = range.upperBound
      }
      parent(cursor..<interval.upperBound)
      return pieces
    }
  }
}
