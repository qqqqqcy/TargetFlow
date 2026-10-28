import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  private let recordingKey = "isRecording"
  private var shouldPersist = false
  private var skipNextPersistence = false

  @Published var isRecording: Bool {
    didSet {
      defer { skipNextPersistence = false }

      // Only persist after onboarding is complete
      if shouldPersist && !skipNextPersistence {
        AppStoragePaths.defaults.set(isRecording, forKey: recordingKey)
      }
    }
  }

  private init() {
    // Always start with false - AppDelegate will set the correct value
    // didSet doesn't fire during initialization, so this won't save
    self.isRecording = false
  }

  /// Enable persistence after onboarding is complete
  func enablePersistence() {
    shouldPersist = true
  }

  /// Get the saved recording preference, if any
  func getSavedPreference() -> Bool? {
    if AppStoragePaths.defaults.object(forKey: recordingKey) != nil {
      return AppStoragePaths.defaults.bool(forKey: recordingKey)
    }
    return nil
  }

  func setRecording(
    _ enabled: Bool,
    persistPreference: Bool = true
  ) {
    skipNextPersistence = !persistPreference
    isRecording = enabled
  }

}
