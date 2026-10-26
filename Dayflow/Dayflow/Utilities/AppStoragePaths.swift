import Foundation

/// Keep the fork's recordings and credentials independent of an installed Dayflow app.
enum AppStoragePaths {
  private static var productionApplicationSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TargetFlow", isDirectory: true)
  }

  /// A debug build with a separate bundle identifier can inspect a database
  /// snapshot without starting capture or touching the installed app's data.
  static let uiPreviewDataDirectory: URL? = {
    #if DEBUG
      guard let path = ProcessInfo.processInfo.environment["TARGETFLOW_UI_PREVIEW_DATA_DIR"] else {
        precondition(
          !(Bundle.main.bundleIdentifier?.hasPrefix("local.targetflow.preview.") ?? false),
          "A UI preview bundle must be launched with its snapshot directory."
        )
        return nil
      }
      guard let bundleID = Bundle.main.bundleIdentifier,
        bundleID.hasPrefix("local.targetflow.preview."), path.hasPrefix("/")
      else {
        fatalError(
          "UI preview requires an independent local.targetflow.preview.* bundle and an absolute snapshot directory."
        )
      }
      let directory = URL(fileURLWithPath: path, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
      let production = productionApplicationSupport.standardizedFileURL.resolvingSymlinksInPath()
      guard directory.path != "/", directory.path != production.path,
        !directory.path.hasPrefix(production.path + "/"),
        !production.path.hasPrefix(directory.path + "/")
      else {
        fatalError(
          "UI preview cannot use the production data directory or one of its parent directories.")
      }
      return directory
    #else
      return nil
    #endif
  }()

  static var isUIPreview: Bool { uiPreviewDataDirectory != nil }

  static var applicationSupport: URL {
    uiPreviewDataDirectory ?? productionApplicationSupport
  }

  /// UserDefaults is isolated by the preview bundle identifier. Never use a
  /// volatile domain as write protection for the production preference domain.
  static func prepareUIPreviewPreferences() {
    guard isUIPreview else { return }
    UserDefaults.standard.set(true, forKey: "didOnboard")
    UserDefaults.standard.set(false, forKey: "isRecording")
    UserDefaults.standard.set(true, forKey: "showDockIcon")
  }

  static var timelapses: URL {
    applicationSupport.appendingPathComponent("timelapses", isDirectory: true)
  }
}
