import Foundation

/// Keep the fork's recordings and credentials independent of an installed Dayflow app.
enum AppStoragePaths {
  static var applicationSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TargetFlow", isDirectory: true)
  }

  static var timelapses: URL {
    applicationSupport.appendingPathComponent("timelapses", isDirectory: true)
  }
}
