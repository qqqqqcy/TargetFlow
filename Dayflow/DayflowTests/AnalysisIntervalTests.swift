import XCTest

@testable import Dayflow

final class AnalysisIntervalTests: XCTestCase {
  func testDefaultPersistenceAndInvalidValues() {
    let suite = "AnalysisIntervalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(AnalysisPreferences.interval(in: defaults), 300)
    XCTAssertEqual(AnalysisPreferences.intervalOptions, [60, 300, 600, 900])
    for interval in [60.0, 300, 600, 900] {
      AnalysisPreferences.setInterval(interval, in: defaults)
      XCTAssertEqual(AnalysisPreferences.interval(in: defaults), interval)
    }
    AnalysisPreferences.setInterval(120, in: defaults)
    XCTAssertEqual(AnalysisPreferences.interval(in: defaults), 900)
    defaults.set(10, forKey: AnalysisPreferences.intervalKey)
    XCTAssertEqual(AnalysisPreferences.interval(in: defaults), 300)
    defaults.set(-1, forKey: AnalysisPreferences.intervalKey)
    XCTAssertEqual(AnalysisPreferences.interval(in: defaults), 300)
  }

  func testAllIntervalsCloseAtTargetAndRetainUnfinishedFrames() {
    for target in [60, 300, 600, 900] {
      let frames = screenshots(Array(stride(from: 0, through: target - 10, by: 10)))
      XCTAssertTrue(batches(frames, target: target).isEmpty)
      let result = batches(frames + screenshots([target]), target: target)
      XCTAssertEqual(result.count, 1)
      XCTAssertEqual(result.first?.duration, Double(target))
      XCTAssertGreaterThanOrEqual(result[0].duration, ScreenshotBatcher.minimumDuration)
    }
  }

  func testCaptureJitterDoesNotCreateUndersizedBatches() {
    for target in [60, 300, 600, 900] {
      let frames = screenshots(Array(stride(from: 0, through: target + 11, by: 11)))
      let result = batches(frames, target: target)
      XCTAssertEqual(result.count, 1)
      XCTAssertGreaterThanOrEqual(result[0].duration, Double(target))
    }
  }

  func testOneMinuteCaptureFrequencyWorksWithFiveMinuteAnalysis() {
    let frames = screenshots(Array(stride(from: 0, through: 660, by: 60)))
    let result = batches(frames, target: 300)
    XCTAssertEqual(result.map(\.duration), [300, 300])
    XCTAssertEqual(result.flatMap(\.screenshots).count, 12)
  }

  func testGapsSplitAndFramesAreNotDuplicated() {
    let frames = screenshots([0, 30, 60, 300, 330, 360, 390, 420, 450, 600])
    let result = batches(frames.reversed(), target: 300)
    XCTAssertEqual(result.map(\.start), [0, 300])
    XCTAssertEqual(result.map(\.end), [60, 450])
    let timestamps = result.flatMap(\.screenshots).map(\.capturedAt)
    XCTAssertEqual(Set(timestamps).count, timestamps.count)
    XCTAssertFalse(timestamps.contains(600))
  }

  private func batches(_ frames: [Screenshot], target: Int) -> [ScreenshotBatch] {
    ScreenshotBatcher.batches(from: frames, targetDuration: Double(target), maxGap: 120)
  }

  private func screenshots(_ timestamps: [Int]) -> [Screenshot] {
    timestamps.map {
      Screenshot(
        id: Int64($0), capturedAt: $0, filePath: "/test/frame.jpg", fileSize: nil,
        idleSecondsAtCapture: nil, isDeleted: false)
    }
  }
}
