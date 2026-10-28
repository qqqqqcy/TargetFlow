import XCTest

@testable import Dayflow

final class TestIsolationTests: XCTestCase {
  func testHostAutomaticallyUsesIsolatedStorageAndPreferences() {
    XCTAssertTrue(AppStoragePaths.isTesting)
    XCTAssertTrue(AppStoragePaths.isIsolated)
    XCTAssertTrue(AppStoragePaths.isSafePreviewDirectory(
      AppStoragePaths.applicationSupport, production: AppStoragePaths.productionApplicationSupport))

    let key = "isolation-check-\(UUID().uuidString)"
    defer { AppStoragePaths.defaults.removeObject(forKey: key) }
    AppStoragePaths.defaults.set("fixture", forKey: key)
    XCTAssertEqual(AppStoragePaths.defaults.string(forKey: key), "fixture")
    XCTAssertNil(UserDefaults.standard.object(forKey: key))
  }

  func testTestDetectionDoesNotRequireAnEnvironmentFlag() {
    XCTAssertTrue(AppStoragePaths.isTestProcess(environment: [:], hasXCTestBundle: true))
    XCTAssertTrue(AppStoragePaths.isTestProcess(
      environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
      hasXCTestBundle: false))
    XCTAssertTrue(AppStoragePaths.isTestProcess(
      environment: ["TARGETFLOW_TEST_MODE": "1"], hasXCTestBundle: false))
    XCTAssertTrue(AppStoragePaths.isTestProcess(
      environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"], hasXCTestBundle: false))
    XCTAssertFalse(AppStoragePaths.isTestProcess(environment: [:], hasXCTestBundle: false))
  }

  func testPreviewRejectsProductionDirectoryAncestorsAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let production = root.appendingPathComponent("production")
    try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: production)

    for unsafe in [root, production, production.appendingPathComponent("child"), alias] {
      XCTAssertFalse(AppStoragePaths.isSafePreviewDirectory(unsafe, production: production))
    }
    XCTAssertTrue(AppStoragePaths.isSafePreviewDirectory(
      root.appendingPathComponent("preview"), production: production))
  }

  func testRecoveryCannotDeleteAReferencedExternalSegment() throws {
    // Simulates a snapshot containing an absolute path to another app's open MP4.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let segment = directory.appendingPathComponent("active.mp4")
    let contents = Data("unfinished segment sentinel".utf8)
    try contents.write(to: segment)
    XCTAssertNotNil(StorageManager.shared.saveScreenshot(
      segmentPath: segment.path, frameIndex: 0,
      capturedAt: Date().addingTimeInterval(3600), idleSecondsAtCapture: 0))

    FrameStore.shared.reconcileAfterLaunch()
    // Wait for any queued recovery work before checking the sentinel.
    _ = FrameStore.shared.activeSegmentPath
    StorageManager.shared.cleanupRecordingStragglers()
    XCTAssertEqual(try Data(contentsOf: segment), contents)
  }

  func testCredentialOperationsUseIsolatedFiles() {
    let provider = "isolation-check-\(UUID().uuidString)"
    XCTAssertTrue(KeychainManager.shared.store("fixture-secret", for: provider))
    XCTAssertEqual(KeychainManager.shared.retrieve(for: provider), "fixture-secret")
    XCTAssertNil(KeychainManager.shared.retrieveWithoutInteraction(for: provider))
    XCTAssertTrue(KeychainManager.shared.delete(for: provider))
    XCTAssertNil(KeychainManager.shared.retrieve(for: provider))
  }
}
