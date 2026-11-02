import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
  static let shared = AppState()

  private let recordingKey = "isRecording"
  private var shouldPersist = false
  private var skipNextPersistence = false
  private let automaticReminders: AutomaticReminderState
  private let pauseReminders: @MainActor () -> Void

  @Published var isRecording: Bool {
    didSet {
      defer { skipNextPersistence = false }
      if oldValue != isRecording { automaticReminders.setRecording(isRecording) }
      if oldValue && !isRecording { pauseReminders() }

      // Only persist after onboarding is complete
      if shouldPersist && !skipNextPersistence {
        AppStoragePaths.defaults.set(isRecording, forKey: recordingKey)
      }
    }
  }

  init(
    automaticReminders: AutomaticReminderState? = nil,
    pauseReminders: @escaping @MainActor () -> Void = { NotificationService.shared.pauseAutomaticReminders() }
  ) {
    self.automaticReminders = automaticReminders ?? .shared
    self.pauseReminders = pauseReminders
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
    // An explicit stopped preference is meaningful even while launch starts at false.
    if !enabled && !isRecording { automaticReminders.setRecording(false) }
    isRecording = enabled
  }

}
