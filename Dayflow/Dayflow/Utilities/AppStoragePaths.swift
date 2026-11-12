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

  private struct TestStorage {
    let directory: URL
    let defaultsDomain: String
  }

  private static let testStorage: TestStorage = {
    let environment = ProcessInfo.processInfo.environment
    let suppliedRunID = environment["TARGETFLOW_TEST_RUN_ID"] ?? ""
    let suppliedRoot = environment["TARGETFLOW_TEST_ROOT"] ?? ""
    let managedRun = !suppliedRunID.isEmpty || !suppliedRoot.isEmpty
    let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    precondition(!managedRun || (!suppliedRunID.isEmpty && suppliedRunID.utf8.count <= 80
      && suppliedRunID.unicodeScalars.allSatisfy { safeCharacters.contains($0) }
      && suppliedRoot.hasPrefix("/")), "Tests require a safe run ID and an absolute test root from the scheme.")
    let runID = managedRun ? suppliedRunID : UUID().uuidString
    let hostID = UUID().uuidString
    // The runner passes this path explicitly through the scheme; TMPDIR may differ
    // between xcodebuild and its parallel test hosts.
    let root = managedRun ? URL(fileURLWithPath: suppliedRoot, isDirectory: true)
      : FileManager.default.temporaryDirectory.appendingPathComponent("TargetFlowTests/\(runID)", isDirectory: true)
    precondition(isSafePreviewDirectory(root, production: productionApplicationSupport),
      "Tests cannot use the production data directory or one of its parent directories.")
    let hostDirectory = root.appendingPathComponent(hostID, isDirectory: true)
    let directory = hostDirectory.appendingPathComponent("data", isDirectory: true)
    let domain = "local.targetflow.tests.\(runID).\(hostID)"
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // Register before opening the suite so even a crashed host can be cleaned up.
      let registration: [String: Any] = [
        "runID": runID, "hostID": hostID, "defaultsDomain": domain,
        "pid": ProcessInfo.processInfo.processIdentifier,
      ]
      let data = try JSONSerialization.data(withJSONObject: registration, options: [.sortedKeys])
      try data.write(to: hostDirectory.appendingPathComponent("host.json"), options: .atomic)
    } catch {
      fatalError("Cannot register isolated test storage: \(error)")
    }
    return TestStorage(directory: directory, defaultsDomain: domain)
  }()

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
    let packagedReplay = previewBundle && Bundle.main.object(forInfoDictionaryKey: "TargetFlowReplayPreview") as? Bool == true
    let packagedDirectory = packagedReplay ? Bundle.main.bundleURL.deletingLastPathComponent() : nil
    if let packagedDirectory, environment["TARGETFLOW_UI_PREVIEW_DATA_DIR"] == nil {
      precondition(FileManager.default.fileExists(atPath: packagedDirectory.appendingPathComponent("manifest.json").path),
        "Keep the replay application beside its recording manifest and data.")
    }
    guard let path = environment["TARGETFLOW_UI_PREVIEW_DATA_DIR"] ?? packagedDirectory?.path else {
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

  /// A replay manifest is accepted only inside an explicitly isolated preview directory.
  static let replayManifestURL: URL? = {
    guard let directory = uiPreviewDataDirectory else { return nil }
    let packagedReplay = Bundle.main.object(forInfoDictionaryKey: "TargetFlowReplayPreview") as? Bool == true
    guard let path = ProcessInfo.processInfo.environment["TARGETFLOW_REPLAY_MANIFEST"]
      ?? (packagedReplay ? directory.appendingPathComponent("manifest.json").path : nil),
      path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(directory.path + "/") else { return nil }
    return url
  }()

  /// Replays simulate feeding saved frames into one recording session. Real gaps,
  /// frame-index discontinuities and day boundaries still use production checks.
  /// Historical sub-cadence pauses were not persisted and cannot be reconstructed.
  static let replayCaptureStartTimestamp: Int? = {
    guard let url = replayManifestURL,
      let data = try? Data(contentsOf: url),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      manifest["version"] as? Int == 1,
      manifest["captureContinuityMode"] as? String == "timestamp-and-frame-index",
      let start = manifest["replayStartTs"] as? Int, start > 0,
      let windows = manifest["windows"] as? [[String: Any]], !windows.isEmpty,
      windows.allSatisfy({ window in
        guard let lower = window["startTs"] as? Int, let upper = window["endTs"] as? Int else { return false }
        return lower >= start && upper > lower
      }) else { return nil }
    return start
  }()

  static var isUIPreview: Bool { uiPreviewDataDirectory != nil }
  static var isIsolated: Bool { isTesting || isUIPreview }

  static var applicationSupport: URL {
    if isTesting { return testStorage.directory }
    return uiPreviewDataDirectory ?? productionApplicationSupport
  }

  /// Tests never read or write the application's persistent preference domain.
  static let defaults: UserDefaults = {
    if isTesting {
      return UserDefaults(suiteName: testStorage.defaultsDomain)!
    }
    // Validate preview identity before any preference access can mutate a domain.
    _ = uiPreviewDataDirectory
    return .standard
  }()

  static func prepareUIPreviewPreferences() {
    guard isIsolated else { return }
    if let manifest = replayManifestURL {
      let seed = manifest.deletingLastPathComponent().appendingPathComponent("replay-preferences.plist")
      if seed.resolvingSymlinksInPath().path.hasPrefix(uiPreviewDataDirectory!.path + "/"),
        let data = try? Data(contentsOf: seed),
        let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
        for (key, value) in values { defaults.set(value, forKey: key) }
      }
    }
    defaults.set(true, forKey: "didOnboard")
    defaults.set(false, forKey: "isRecording")
    defaults.set(true, forKey: "showDockIcon")
  }

  /// Snapshots can carry absolute paths. Cleanup in an isolated process may
  /// only remove generated media physically inside that process's own root.
  static func canRemoveGeneratedMedia(at url: URL) -> Bool {
    guard isIsolated else { return true }
    let root = applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path.hasPrefix(root + "/")
  }

  static var timelapses: URL {
    applicationSupport.appendingPathComponent("timelapses", isDirectory: true)
  }
}
