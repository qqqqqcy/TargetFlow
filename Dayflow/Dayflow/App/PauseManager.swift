//
//  PauseManager.swift
//  Dayflow
//
//  Manages pause functionality for recording.
//  Timed pauses are session-local, while indefinite pause keeps recording off until resumed.
//

import AppKit
import Combine
import Foundation

// MARK: - Pause Types

enum PauseDuration: Equatable {
  case timed(minutes: Int)
  case indefinite

  var timeInterval: TimeInterval? {
    switch self {
    case .timed(let minutes): return TimeInterval(minutes * 60)
    case .indefinite: return nil
    }
  }

  /// Short label for chips and menu segments, e.g. "15m", "1h", "1h 30m".
  var shortLabel: String {
    switch self {
    case .timed(let minutes):
      return Duration.seconds(minutes * 60)
        .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    case .indefinite:
      return "∞"
    }
  }
}

/// The three timed pause lengths offered in the menu bar and the main window.
/// Editable in Settings.
enum PausePresets {
  static let defaultMinutes = [15, 30, 60]
  private static let storageKey = "pausePresetMinutes"

  static var minutes: [Int] {
    get {
      let stored = AppStoragePaths.defaults.array(forKey: storageKey) as? [Int] ?? []
      return stored.count == defaultMinutes.count ? stored : defaultMinutes
    }
    set { AppStoragePaths.defaults.set(newValue, forKey: storageKey) }
  }

  /// The timed presets followed by the indefinite pause.
  static var durations: [PauseDuration] {
    minutes.map { .timed(minutes: $0) } + [.indefinite]
  }
}

@MainActor
final class PauseManager: ObservableObject {
  static let shared = PauseManager()

  /// When the timed pause should end. nil = not on a timed pause.
  @Published private(set) var pauseEndTime: Date?

  /// True if user selected indefinite pause (∞). Separate from timed pause.
  @Published private(set) var isPausedIndefinitely: Bool = false

  /// Convenience: true if any kind of user-initiated pause is active
  var isPaused: Bool {
    isPausedIndefinitely || pauseEndTime != nil
  }

  /// Remaining seconds for countdown display. nil if not on timed pause.
  var remainingSeconds: Int? {
    guard let end = pauseEndTime else { return nil }
    let remaining = end.timeIntervalSinceNow
    return remaining > 0 ? Int(ceil(remaining)) : 0
  }

  private var timer: Timer?

  private init() {
    registerForWakeNotification()
  }

  // MARK: - Public API

  func clearPauseState() {
    stopTimer()
    pauseEndTime = nil
    isPausedIndefinitely = false
  }

  /// Pause recording for a specific duration.
  func pause(for duration: PauseDuration) {
    clearPauseState()

    if let interval = duration.timeInterval {
      // Timed pause
      pauseEndTime = Date().addingTimeInterval(interval)
      isPausedIndefinitely = false
      startTimer()
    } else {
      // Indefinite pause
      pauseEndTime = nil
      isPausedIndefinitely = true
    }

    // Stop recording
    AppState.shared.setRecording(
      false,
      persistPreference: duration == .indefinite
    )
  }

  /// Resume recording immediately.
  func resume() {
    clearPauseState()

    // Start recording
    AppState.shared.setRecording(true)
  }

  // MARK: - Timer Management

  private func startTimer() {
    timer?.invalidate()

    // Fire every second to update the countdown display
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.timerTick()
      }
    }

    // Ensure timer fires even when menu is open (modal runloop)
    if let timer = timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func timerTick() {
    // Trigger UI update by notifying observers
    objectWillChange.send()

    // Check if pause has expired
    checkAndResumeIfExpired()
  }

  private func checkAndResumeIfExpired() {
    guard let end = pauseEndTime else { return }

    if Date() >= end {
      resume()
    }
  }

  // MARK: - Wake Notification

  private func registerForWakeNotification() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleWake()
      }
    }
  }

  private func handleWake() {
    // If we were on a timed pause and it has now expired, auto-resume
    // This handles the case where computer slept past the pause end time
    if let end = pauseEndTime, Date() >= end {
      resume()
    }
    // If paused indefinitely, stay paused (no action needed)
  }
}
