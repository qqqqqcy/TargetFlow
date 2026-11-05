import Foundation
import XCTest
@testable import Dayflow

final class TimelineStabilizationTests: XCTestCase {
  private let base = 1_800_000_000
  private func cards(_ events: [(String, Int)]) -> [ActivityCardData] {
    var cursor = base
    return events.enumerated().map { index, event in
      let end = cursor + event.1 * 60
      defer { cursor = end }
      let clock = TimelineOutputPolicy()
      return ActivityCardData(startTime: clock.formatTimestampForPrompt(cursor), endTime: clock.formatTimestampForPrompt(end),
        category: event.0, subcategory: "", title: "Fact \(index)", summary: "Summary \(index)",
        detailedSummary: "Detail \(index)", distractions: nil, appSites: nil)
    }
  }

  func testShortSwitchIsAbsorbedWithoutHole() throws {
    let plan = try TimelineStabilizationPolicy.plan(cards([("A", 6), ("B", 2), ("A", 6)]), nearest: base, minimum: 300)
    XCTAssertEqual(plan.count, 1)
    XCTAssertEqual(plan[0].range, base..<base + 840)
    XCTAssertEqual(plan[0].category, "A")
    XCTAssertEqual(plan[0].sourceIndices, [0, 1, 2])
  }

  func testDifferentStableNeighborsRemainDistinctAndTieGoesEarlier() throws {
    let plan = try TimelineStabilizationPolicy.plan(cards([("A", 6), ("B", 2), ("C", 6)]), nearest: base, minimum: 300)
    XCTAssertEqual(plan.map(\.category), ["A", "C"])
    XCTAssertEqual(plan.map(\.range), [base..<base + 480, base + 480..<base + 840])
  }

  func testShortOnlyRunUsesTimeMajorityAndThresholdIsConfigurable() throws {
    let input = cards([("A", 2), ("B", 2), ("A", 2)])
    let plan = try TimelineStabilizationPolicy.plan(input, nearest: base, minimum: 300)
    XCTAssertEqual(plan.map(\.category), ["A"])
    XCTAssertEqual(plan[0].range.count, 360)
    XCTAssertEqual(try TimelineStabilizationPolicy.plan(input, nearest: base, minimum: 60).count, 3)
    let pending = try TimelineStabilizationPolicy.plan(cards([("A", 2), ("B", 2)]), nearest: base, minimum: 300)
    XCTAssertEqual(pending.map(\.category), ["A"])
    XCTAssertEqual(pending[0].range.count, 240)
    let changingWindows = try TimelineStabilizationPolicy.plan(cards([("A", 2), ("B", 2), ("A", 1),
      ("C", 2), ("D", 2), ("C", 1)]), nearest: base, minimum: 300)
    XCTAssertEqual(changingWindows.map(\.category), ["A", "C"])
  }

  func testGapFourAMAndMaximumDurationAreHardBoundaries() throws {
    var gapped = cards([("A", 6), ("B", 2), ("A", 6)])
    gapped.remove(at: 1)
    XCTAssertEqual(try TimelineStabilizationPolicy.plan(gapped, nearest: base, minimum: 300).count, 2)
    let long = try TimelineStabilizationPolicy.plan(cards([("A", 60), ("A", 1)]), nearest: base, minimum: 300)
    XCTAssertEqual(long.map { $0.range.count }, [3360, 300])
    let boundary = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2027, month: 5, day: 10, hour: 4)))
    let clock = TimelineOutputPolicy()
    let start = Int(boundary.timeIntervalSince1970) - 300
    let across = ActivityCardData(startTime: clock.formatTimestampForPrompt(start), endTime: clock.formatTimestampForPrompt(start + 600),
      category: "A", subcategory: "", title: "Across", summary: "Across", detailedSummary: "Across", distractions: nil, appSites: nil)
    let split = try TimelineStabilizationPolicy.plan([across], nearest: start, minimum: 300)
    XCTAssertEqual(split.map { $0.range.count }, [300, 300])
  }

  func testGenerateRequestsNaturalRewriteAndEnforcesFrozenPlanWithSafeFallback() async throws {
    let defaults = AppStoragePaths.defaults
    let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = old
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain) }
    let input = cards([("Idle", 6), ("B", 2), ("Idle", 6)])
    let frames = (0..<14).map { minute in
      Screenshot(id: Int64(minute + 1), capturedAt: base + minute * 60, filePath: "stable",
        fileSize: nil, idleSecondsAtCapture: 0, isDeleted: false, frameIndex: minute)
    }
    let context = ActivityGenerationContext(batchObservations: [], existingCards: [],
      currentTime: Date(timeIntervalSince1970: Double(base + 840)),
      categories: [LLMCategoryDescriptor(id: UUID(), name: "B", colorHex: "#FFFFFF", description: "Switch", isSystem: false, isIdle: false)],
      hasPreviousCardWithinFiveMinutes: false)
    var calls = 0
    let result = try await TimelineEvidencePolicy.generate(screenshots: frames, context: context, batchId: nil,
      recordedContinuity: { _, _ in true }) { _, request, _ in
        calls += 1
        if calls == 2 {
          XCTAssertEqual(request.correctionCards.count, 3)
          XCTAssertTrue(try TimelineEvidencePolicy.correctionInstruction(request.correctionCards).contains("REQUIRED stability plan"))
        }
        // Deliberately ignore correction: bounded fallback must cover all 14 minutes.
        return (input, [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
      }
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(result.cards.count, 1)
    XCTAssertEqual(result.cards[0].category, "Idle")
    XCTAssertEqual(result.cards[0].sourceScreenshotIDs, frames.map(\.id))
    XCTAssertEqual(try ClaudeOutputValidator.resolveActivityCardInterval(result.cards[0], nearest: base), base..<base + 840)
    for fact in ["Fact 0", "Fact 1", "Fact 2", "Detail 1"] { XCTAssertTrue(result.cards[0].detailedSummary.contains(fact)) }
  }

  func testGeneratePreservesStableHistoryButCanReclassifyShortHistory() async throws {
    let defaults = AppStoragePaths.defaults
    let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = old
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain) }
    let descriptors = ["A", "B"].map {
      LLMCategoryDescriptor(id: UUID(), name: $0, colorHex: "#FFFFFF", description: $0, isSystem: false, isIdle: false)
    }
    for historyMinutes in [2, 6] {
      let input = cards([("B", historyMinutes), ("A", 6)])
      let frames = (historyMinutes..<(historyMinutes + 6)).map { minute in
        Screenshot(id: Int64(minute), capturedAt: base + minute * 60, filePath: "history",
          fileSize: nil, idleSecondsAtCapture: 0, isDeleted: false, frameIndex: minute)
      }
      let context = ActivityGenerationContext(batchObservations: [], existingCards: [input[0]],
        currentTime: Date(timeIntervalSince1970: Double(base + (historyMinutes + 6) * 60)),
        categories: descriptors, hasPreviousCardWithinFiveMinutes: true, hasContinuousCaptureBeforeBatch: true)
      let flatten = ActivityCardData(startTime: input[0].startTime, endTime: input[1].endTime,
        category: "A", subcategory: "", title: "Natural A", summary: "Account of A", detailedSummary: "New fact",
        distractions: nil, appSites: nil)
      var calls = 0
      let result = try await TimelineEvidencePolicy.generate(screenshots: frames, context: context, batchId: nil,
        recordedContinuity: { _, _ in true }) { _, _, _ in
          calls += 1
          return ([flatten], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
        }
      XCTAssertEqual(result.cards.map(\.category), historyMinutes == 2 ? ["A"] : ["B", "A"])
      XCTAssertEqual(calls, historyMinutes == 2 ? 1 : 2)
      XCTAssertTrue(result.cards[0].detailedSummary.contains("Detail 0"))
      let groups = try TimelineEvidencePolicy.replacementGroups(result.cards, nearest: base)
      XCTAssertEqual(groups.count, 1)
      XCTAssertEqual(groups[0].range, base..<base + (historyMinutes + 6) * 60)
    }
  }

  func testVerifiedPlanRetainsSpanningEvidenceInEveryIntersectingGroup() throws {
    let output = cards([("A", 6), ("B", 6)])
    let source = cards([("A", 12)])
    let plan = try TimelineStabilizationPolicy.plan(output, nearest: base, minimum: 300)
    let retained = try TimelineEvidencePolicy.preserveRewrittenFacts(output, previous: source,
      nearest: base, descriptors: [], verifiedStabilityPlan: plan)
    XCTAssertTrue(retained.allSatisfy { $0.detailedSummary.contains("Detail 0") })
  }

  func testCancellationDuringCorrectionPropagatesWithoutFallback() async throws {
    let input = cards([("Idle", 1), ("Idle", 1)])
    let frames = (0..<2).map { minute in
      Screenshot(id: Int64(minute), capturedAt: base + minute * 60, filePath: "cancel",
        fileSize: nil, idleSecondsAtCapture: 0, isDeleted: false, frameIndex: minute)
    }
    let context = ActivityGenerationContext(batchObservations: [], existingCards: [],
      currentTime: Date(timeIntervalSince1970: Double(base + 120)), categories: [], hasPreviousCardWithinFiveMinutes: false)
    var calls = 0
    do {
      _ = try await TimelineEvidencePolicy.generate(screenshots: frames, context: context, batchId: nil,
        recordedContinuity: { _, _ in true }) { _, _, _ in
          calls += 1
          if calls == 2 { throw CancellationError() }
          return (input, [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
        }
      XCTFail("Cancelled correction must not return fallback cards")
    } catch is CancellationError {
      XCTAssertEqual(calls, 2)
    }
  }

  func testGenerateRetainsConnectedHistoryAndNaturalProviderProse() async throws {
    let defaults = AppStoragePaths.defaults
    let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var arguments = old
    arguments[AnalysisPreferences.intervalKey] = 300
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain) }
    let input = cards([("Idle", 2), ("Idle", 2), ("Idle", 2)])
    let frames = (4..<6).map { minute in
      Screenshot(id: Int64(minute), capturedAt: base + minute * 60, filePath: "stable",
        fileSize: nil, idleSecondsAtCapture: 0, isDeleted: false, frameIndex: minute)
    }
    let context = ActivityGenerationContext(batchObservations: [], existingCards: Array(input.prefix(2)),
      currentTime: Date(timeIntervalSince1970: Double(base + 360)), categories: [], hasPreviousCardWithinFiveMinutes: true,
      hasContinuousCaptureBeforeBatch: true)
    var calls = 0
    let result = try await TimelineEvidencePolicy.generate(screenshots: frames, context: context, batchId: nil,
      recordedContinuity: { _, _ in true }) { _, request, _ in
        calls += 1
        XCTAssertEqual(request.existingCards.count, 2)
        if calls == 1 { return (input, [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil)) }
        let natural = ActivityCardData(startTime: input[0].startTime, endTime: input[2].endTime,
          category: "Idle", subcategory: "", title: "Natural rewritten title", summary: "A coherent account.",
          detailedSummary: "Rewritten details", distractions: nil, appSites: nil)
        return ([natural], [], nil, LLMCall(timestamp: nil, latency: nil, input: nil, output: nil))
      }
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(result.cards.first?.title, "Natural rewritten title")
    XCTAssertEqual(result.cards.first?.summary, "A coherent account.")
    XCTAssertTrue(result.cards[0].detailedSummary.contains("Detail 2"))
    XCTAssertEqual(result.rewriteSpan, base..<base + 360)
  }
}
