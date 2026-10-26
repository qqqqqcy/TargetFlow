//
//  UpdaterManager.swift
//  Dayflow
//

import Combine

/// Inert compatibility surface for legacy views. This fork never starts an updater.
@MainActor
final class UpdaterManager: ObservableObject {
  static let shared = UpdaterManager()

  @Published var isChecking = false
  @Published var statusText = "Updates are disabled in this local build."
  @Published var updateAvailable = false
  @Published var latestVersionString: String? = nil

  private init() {}

  func checkForUpdates(showUI: Bool = false) {}
}
