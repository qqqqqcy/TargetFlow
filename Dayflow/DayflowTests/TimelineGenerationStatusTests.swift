import XCTest
@testable import Dayflow

final class TimelineGenerationStatusTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testOnlyLiveAnalysisUsesCurrentRecordingAnalyzingLabel() {
    XCTAssertEqual(status(analyzing: true, recovering: true), .analyzing)
    XCTAssertEqual(status(queued: true, recovering: true), .queued)
    XCTAssertEqual(status(recovering: true), .recovering)
    XCTAssertNotEqual(status(recovering: true).title, status(analyzing: true).title)
  }

  func testCollectionCountdownSurvivesHistoricalRecovery() {
    XCTAssertEqual(status(recovering: true, after: 121), .collecting(seconds: 121))
    XCTAssertEqual(status(recovering: true, after: -1), .ready)
  }

  func testPendingFactsAndNoWorkAreNotReportedAsModelGeneration() {
    XCTAssertEqual(status(recovering: true, pending: 180), .stabilizing)
    XCTAssertEqual(status(), .waiting)
    XCTAssertEqual(status(analyzing: true, pending: 180), .analyzing)
    XCTAssertEqual(status(queued: true, pending: 180), .queued)
  }

  private func status(analyzing: Bool = false, queued: Bool = false,
    recovering: Bool = false, after: TimeInterval? = nil, pending: TimeInterval? = nil
  ) -> TimelineGenerationStatus {
    .resolve(liveAnalyzing: analyzing, liveQueued: queued, recovering: recovering,
      deadline: after.map { now.addingTimeInterval($0) }, pendingDuration: pending, now: now)
  }
}
