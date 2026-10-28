import Foundation

/// Test hosts and screenshot previews must never fall back to the user's data.
enum AppStoragePaths {
  static var productionApplicationSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TargetFlow", isDirectory: true)
  }

  static func isTestProcess(environment: [String: String], hasXCTestBundle: Bool) -> Bool {
    hasXCTestBundle || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
      || environment["TARGETFLOW_TEST_MODE"] == "1"
      || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
  }

  static let isTesting = isTestProcess(
    environment: ProcessInfo.processInfo.environment,
    hasXCTestBundle: NSClassFromString("XCTestCase") != nil
      || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
  )

  private static let testIdentifier = UUID().uuidString
  private static let testDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("TargetFlowTests/\(testIdentifier)", isDirectory: true)

  static func isSafePreviewDirectory(_ directory: URL, production: URL) -> Bool {
    let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
    let productionPath = production.standardizedFileURL.resolvingSymlinksInPath().path
    return path != "/" && path != productionPath
      && !path.hasPrefix(productionPath + "/") && !productionPath.hasPrefix(path + "/")
  }

  /// Requires both an independent application identity and an explicit data directory.
  static let uiPreviewDataDirectory: URL? = {
    let environment = ProcessInfo.processInfo.environment
    let previewBundle = Bundle.main.bundleIdentifier?.hasPrefix("local.targetflow.preview.") ?? false
    guard let path = environment["TARGETFLOW_UI_PREVIEW_DATA_DIR"] else {
      precondition(!previewBundle, "A UI preview bundle must be launched with its snapshot directory.")
      return nil
    }
    guard previewBundle, path.hasPrefix("/") else {
      fatalError("UI preview requires an independent local.targetflow.preview.* bundle and an absolute snapshot directory.")
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard isSafePreviewDirectory(directory, production: productionApplicationSupport) else {
      fatalError("UI preview cannot use the production data directory or one of its parent directories.")
    }
    return directory
  }()

  static var isUIPreview: Bool { uiPreviewDataDirectory != nil }
  static var isIsolated: Bool { isTesting || isUIPreview }

  static var applicationSupport: URL {
    if isTesting { return testDirectory }
    return uiPreviewDataDirectory ?? productionApplicationSupport
  }

  /// Tests never read or write the application's persistent preference domain.
  static let defaults: UserDefaults = {
    if isTesting {
      return UserDefaults(suiteName: "local.targetflow.tests.\(testIdentifier)")!
    }
    // Validate preview identity before any preference access can mutate a domain.
    _ = uiPreviewDataDirectory
    return .standard
  }()

  static func prepareUIPreviewPreferences() {
    guard isIsolated else { return }
    defaults.set(true, forKey: "didOnboard")
    defaults.set(false, forKey: "isRecording")
    defaults.set(true, forKey: "showDockIcon")
  }

  static var timelapses: URL {
    applicationSupport.appendingPathComponent("timelapses", isDirectory: true)
  }
}
