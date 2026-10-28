import XCTest

@testable import Dayflow

final class TargetFlowScopeTests: XCTestCase {
  func testNavigationExposesOnlyTimelineAndSettings() {
    XCTAssertEqual(SidebarIcon.allCases.map(\.rawValue), ["timeline", "settings"])
  }

  func testStorageAndTimelapsesDoNotShareUpstreamDirectory() {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let upstream = support.appendingPathComponent("Dayflow", isDirectory: true)
    let fork = AppStoragePaths.applicationSupport

    XCTAssertTrue(AppStoragePaths.isTesting)
    XCTAssertTrue(AppStoragePaths.isIsolated)
    XCTAssertNotEqual(fork, support.appendingPathComponent("TargetFlow", isDirectory: true))
    XCTAssertTrue(fork.path.contains("TargetFlowTests/"))
    XCTAssertNotEqual(fork, upstream)
    XCTAssertEqual(
      AppStoragePaths.timelapses,
      fork.appendingPathComponent("timelapses", isDirectory: true))
  }

}
