import Foundation
import ScreenCaptureKit

enum RecordingControlMode: Equatable {
  case active
  case pausedTimed(endTime: Date)
  case pausedIndefinite
  case stopped
}

@MainActor
enum RecordingControl {
  static func currentMode() -> RecordingControlMode {
    currentMode(appState: .shared, pauseManager: .shared)
  }

  static func currentMode(
    appState: AppState,
    pauseManager: PauseManager
  ) -> RecordingControlMode {
    if appState.isRecording && pauseManager.isPaused {
      assertionFailure("Recording cannot be active while pause metadata is still set")
      return .active
    }

    if let endTime = pauseManager.pauseEndTime {
      return .pausedTimed(endTime: endTime)
    }

    if pauseManager.isPausedIndefinitely {
      return .pausedIndefinite
    }

    return appState.isRecording ? .active : .stopped
  }

  static func start() {
    Task { @MainActor in
      // Preflight only: an SCShareableContent probe here would be one more
      // ScreenCaptureKit request for macOS to re-check (issue #381), and the
      // recorder handles a start that fails anyway.
      guard ScreenRecordingPermissionNotice.isGranted else {
        print("[RecordingControl] Screen recording permission not granted; start ignored")
        ScreenRecordingPermissionNotice.post(reason: "recording_control_start")
        return
      }

      PauseManager.shared.clearPauseState()
      AppState.shared.setRecording(true)
    }
  }

  static func stop() {
    PauseManager.shared.clearPauseState()
    AppState.shared.setRecording(false)
  }
}
