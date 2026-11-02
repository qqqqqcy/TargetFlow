import Foundation

/// A pause invalidates in-flight work even if recording resumes before it completes.
@MainActor
final class AutomaticReminderState {
  static let shared = AutomaticReminderState(isRecording: false)

  private(set) var isRecording: Bool
  private(set) var generation = UUID()
  private(set) var resumedAt = Date.distantPast
  private var hasStopped = false

  init(isRecording: Bool) {
    self.isRecording = isRecording
  }

  func setRecording(_ enabled: Bool, now: Date = Date()) {
    if !enabled { hasStopped = true }
    guard enabled != isRecording else { return }
    generation = UUID()
    isRecording = enabled
    // The initial false value is a launch placeholder, not a user pause.
    if enabled && hasStopped { resumedAt = now }
  }

  func allows(_ generation: UUID, eventEnd: Date? = nil) -> Bool {
    isRecording && self.generation == generation
      && (eventEnd.map { $0 > resumedAt } ?? true)
  }
}
