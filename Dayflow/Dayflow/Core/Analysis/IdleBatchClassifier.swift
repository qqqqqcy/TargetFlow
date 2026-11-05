//
//  IdleBatchClassifier.swift
//  Dayflow
//
//  Pure classification of screenshot batches as fully idle, so the analysis
//  pipeline can skip the LLM and write an Idle card directly.
//

import Foundation
import CoreGraphics

enum IdleBatchRules {
  static let classifierVersion = "unchanged_input_inactive_v4"
  static let historyCadenceAllowanceSeconds = 120
  // 15-minute threshold + 2-minute cadence allowance + 15-minute batch at 1 Hz
  // needs at most 1,921 frames, including both endpoints.
  static let maximumComparedFrames = 2048

  static func historyLookbackSeconds(thresholdSeconds: Int) -> Int {
    thresholdSeconds + historyCadenceAllowanceSeconds
  }
  static let requiredCoverageRatio = 0.95
  static let requiredIdleSampleAvailabilityRatio = 0.90
  static let maxAllowedUncoveredGapSeconds = 30
  static let mergeGapSeconds = 5 * 60
}

struct IdleBatchAssessment {
  let thresholdSeconds: Int
  let classifierVersion: String
  let coverageRatio: Double
  let coveredSeconds: Int
  let batchDurationSeconds: Int
  let largestUncoveredGapSeconds: Int
  let screenshotCount: Int
  let sampledIdleScreenshotCount: Int
  let averageIdleSecondsAtCapture: Double
  let maxIdleSecondsAtCapture: Int
}

enum IdleBatchClassifier {
  static func assess(
    _ screenshots: [Screenshot], history: [Screenshot] = [], evidenceSince: Int? = nil,
    thresholdSeconds: Int = InactivityPreferences.thresholdSeconds,
    pixels: (Screenshot) -> [UInt8]? = screenPixels
  ) -> IdleBatchAssessment? {
    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    guard let first = ordered.first, let last = ordered.last,
      !ordered.contains(where: \.isDeleted),
      evidenceSince.map({ first.capturedAt >= $0 }) ?? true
    else { return nil }

    guard InactivityPreferences.thresholdOptions.contains(thresholdSeconds) else { return nil }
    // A whole unchanged batch may qualify once the selected duration is reached
    // at its end; earlier cards are retained and never relabeled retroactively.
    let windowStart = last.capturedAt - thresholdSeconds
    let preceding = history.filter {
      $0.capturedAt <= first.capturedAt
        && $0.capturedAt >= windowStart - IdleBatchRules.historyCadenceAllowanceSeconds
    }
      .filter { frame in
        frame.id != first.id && (evidenceSince.map { frame.capturedAt >= $0 } ?? true)
      }
    let window = (preceding + ordered).sorted { $0.capturedAt < $1.capturedAt }
    guard window.count <= IdleBatchRules.maximumComparedFrames, let baselineFrame = window.first,
      baselineFrame.capturedAt <= windowStart,
      !window.contains(where: \.isDeleted),
      let baseline = pixels(baselineFrame), !baseline.isEmpty
    else { return nil }
    let gaps = zip(window, window.dropFirst()).map { $1.capturedAt - $0.capturedAt }.filter { $0 > 0 }.sorted()
    guard !gaps.isEmpty else { return nil }
    // Lower quartile resists a few missing captures inflating the expected cadence.
    let expectedCadence = gaps[gaps.count / 4]
    let maximumGap = min(120, max(2, Int(Double(expectedCadence) * 1.5) + 1))
    for (index, frame) in window.enumerated() {
      guard let idle = frame.idleSecondsAtCapture,
        idle >= frame.capturedAt - baselineFrame.capturedAt,
        index == 0 || frame.capturedAt - window[index - 1].capturedAt <= maximumGap,
        let sample = pixels(frame), isSimilar(baseline, sample)
      else { return nil }
    }

    let batchStartTs = first.capturedAt
    let batchEndTs = last.capturedAt
    let batchDurationSeconds = batchEndTs - batchStartTs
    guard
      batchDurationSeconds > 0
    else { return nil }

    let idleSamples = ordered.compactMap { screenshot -> (capturedAt: Int, idleSeconds: Int)? in
      // Zero at the first frame is valid evidence of the run's input onset.
      guard let idleSeconds = screenshot.idleSecondsAtCapture, idleSeconds >= 0 else { return nil }
      return (capturedAt: screenshot.capturedAt, idleSeconds: idleSeconds)
    }

    guard idleSamples.isEmpty == false else { return nil }

    let mergedCoverage = mergeCoverageSegments(
      idleSamples: idleSamples,
      batchStartTs: batchStartTs,
      batchEndTs: batchEndTs
    )
    let coveredSeconds = mergedCoverage.reduce(0) { partial, segment in
      partial + max(0, segment.end - segment.start)
    }
    let uncoveredSegments = invertedCoverageSegments(
      mergedCoverage,
      batchStartTs: batchStartTs,
      batchEndTs: batchEndTs
    )
    let largestUncoveredGapSeconds = uncoveredSegments.map { max(0, $0.end - $0.start) }.max() ?? 0
    let coverageRatio = Double(coveredSeconds) / Double(batchDurationSeconds)
    let idleValues = idleSamples.map(\.idleSeconds)
    // Every frame already proves no input since the fixed baseline. Requiring a
    // further share of samples to be idle for 60 seconds would delay a true
    // five-minute run that begins immediately after the user's last input.
    let idleSampleAvailabilityRatio = Double(idleValues.count) / Double(ordered.count)

    guard
      coverageRatio >= IdleBatchRules.requiredCoverageRatio,
      idleSampleAvailabilityRatio >= IdleBatchRules.requiredIdleSampleAvailabilityRatio,
      largestUncoveredGapSeconds <= IdleBatchRules.maxAllowedUncoveredGapSeconds
    else {
      return nil
    }

    let averageIdleSeconds = Double(idleValues.reduce(0, +)) / Double(idleValues.count)

    return IdleBatchAssessment(
      thresholdSeconds: thresholdSeconds,
      classifierVersion: IdleBatchRules.classifierVersion,
      coverageRatio: coverageRatio,
      coveredSeconds: coveredSeconds,
      batchDurationSeconds: batchDurationSeconds,
      largestUncoveredGapSeconds: largestUncoveredGapSeconds,
      screenshotCount: ordered.count,
      sampledIdleScreenshotCount: idleSamples.count,
      averageIdleSecondsAtCapture: averageIdleSeconds,
      maxIdleSecondsAtCapture: idleValues.max() ?? 0
    )
  }

  static func makeIdleCard(
    from startDate: Date,
    to endDate: Date,
    metadata: IdleCardMetadata
  ) -> TimelineCardShell {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    let minutes = (metadata.inactivityThresholdSeconds ?? InactivityPreferences.defaultThreshold) / 60
    let detailedSummary = String(localized:
      "At least \(minutes) minutes with no input and no meaningful visible screen change. This is a heuristic, not proof of intent.")

    return TimelineCardShell(
      startTimestamp: formatter.string(from: startDate),
      endTimestamp: formatter.string(from: endDate),
      category: "Idle",
      subcategory: "",
      title: "Idle",
      summary: String(localized: "No input and no meaningful visible screen change for at least \(minutes) minutes."),
      detailedSummary: detailedSummary,
      distractions: nil,
      appSites: nil,
      idleMetadata: metadata,
      evidenceKind: .inputInactive
    )
  }

  static func isSimilar(_ baseline: [UInt8], _ sample: [UInt8]) -> Bool {
    guard !baseline.isEmpty, baseline.count == sample.count else { return false }
    var totalDifference = 0
    var changed = 0
    for (a, b) in zip(baseline, sample) {
      let delta = abs(Int(a) - Int(b))
      totalDifference += delta
      if delta > 12 { changed += 1 }
    }
    return Double(totalDifference) / Double(baseline.count) <= 1.5
      && Double(changed) / Double(baseline.count) <= 0.005
  }

  static func screenPixels(_ screenshot: Screenshot) -> [UInt8]? {
    guard !screenshot.isDeleted,
      let image = FrameStore.shared.image(for: screenshot, maxPixelSize: 96)
    else { return nil }
    var bytes = [UInt8](repeating: 0, count: 96 * 54)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: 96, height: 54, bitsPerComponent: 8,
        bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
      else { return false }
      context.interpolationQuality = .low
      context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 54))
      return true
    }
    return drawn ? bytes : nil
  }

  private static func mergeCoverageSegments(
    idleSamples: [(capturedAt: Int, idleSeconds: Int)],
    batchStartTs: Int,
    batchEndTs: Int
  ) -> [(start: Int, end: Int)] {
    let clipped = idleSamples.compactMap { sample -> (start: Int, end: Int)? in
      let start = max(batchStartTs, sample.capturedAt - sample.idleSeconds)
      let end = min(batchEndTs, sample.capturedAt)
      guard end > start else { return nil }
      return (start, end)
    }.sorted { lhs, rhs in
      if lhs.start == rhs.start {
        return lhs.end < rhs.end
      }
      return lhs.start < rhs.start
    }

    guard let first = clipped.first else { return [] }

    var merged: [(start: Int, end: Int)] = [first]
    for segment in clipped.dropFirst() {
      var last = merged.removeLast()
      if segment.start <= last.end {
        last.end = max(last.end, segment.end)
        merged.append(last)
      } else {
        merged.append(last)
        merged.append(segment)
      }
    }
    return merged
  }

  private static func invertedCoverageSegments(
    _ mergedCoverage: [(start: Int, end: Int)],
    batchStartTs: Int,
    batchEndTs: Int
  ) -> [(start: Int, end: Int)] {
    guard batchEndTs > batchStartTs else { return [] }
    guard mergedCoverage.isEmpty == false else { return [(batchStartTs, batchEndTs)] }

    var gaps: [(start: Int, end: Int)] = []
    var cursor = batchStartTs

    for segment in mergedCoverage {
      if segment.start > cursor {
        gaps.append((cursor, segment.start))
      }
      cursor = max(cursor, segment.end)
    }

    if cursor < batchEndTs {
      gaps.append((cursor, batchEndTs))
    }

    return gaps
  }
}
