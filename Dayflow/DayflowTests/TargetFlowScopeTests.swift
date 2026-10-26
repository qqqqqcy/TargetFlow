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

    XCTAssertEqual(fork, support.appendingPathComponent("TargetFlow", isDirectory: true))
    XCTAssertNotEqual(fork, upstream)
    XCTAssertEqual(
      AppStoragePaths.timelapses,
      fork.appendingPathComponent("timelapses", isDirectory: true))
  }

  func testTelemetryCannotBeEnabledWithoutAnOptInSurface() {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "analyticsOptIn")
    defer {
      if let previous {
        defaults.set(previous, forKey: "analyticsOptIn")
      } else {
        defaults.removeObject(forKey: "analyticsOptIn")
      }
    }

    defaults.set(true, forKey: "analyticsOptIn")
    XCTAssertFalse(AnalyticsService.shared.isOptedIn)
    AnalyticsService.shared.isOptedIn = true
    XCTAssertFalse(AnalyticsService.shared.isOptedIn)
  }
}
