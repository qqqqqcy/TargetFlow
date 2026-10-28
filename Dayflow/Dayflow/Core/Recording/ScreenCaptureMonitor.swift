import AppKit
import Foundation

final class ScreenCaptureMonitor: @unchecked Sendable {
  static let shared = ScreenCaptureMonitor()

  private let lock = NSLock()
  private var isObserving = false

  // Screen availability (guarded by `lock`)
  private var screenLocked = false
  private var screensaverRunning = false
  private var systemAsleep = false

  private init() {}

  // MARK: - Screen availability

  /// True while the screen is locked, asleep, or showing the screensaver.
  /// Nothing useful can be captured then, and requests only add tccd load.
  var isCaptureBlocked: Bool {
    lock.withLock { screenLocked || screensaverRunning || systemAsleep }
  }

  /// Registers the lock / sleep / screensaver observers. Safe to call more than once.
  func startObserving() {
    let shouldStart = lock.withLock {
      guard !isObserving else { return false }
      isObserving = true
      return true
    }
    guard shouldStart else { return }

    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()

    workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) {
      [weak self] _ in
      self?.update { $0.systemAsleep = true }
    }
    workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) {
      [weak self] _ in
      self?.update {
        $0.systemAsleep = false
      }
    }
    distributed.addObserver(
      forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil
    ) { [weak self] _ in
      self?.update { $0.screenLocked = true }
    }
    distributed.addObserver(
      forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil
    ) { [weak self] _ in
      self?.update {
        $0.screenLocked = false
      }
    }
    distributed.addObserver(
      forName: .init("com.apple.screensaver.didstart"), object: nil, queue: nil
    ) { [weak self] _ in
      self?.update { $0.screensaverRunning = true }
    }
    distributed.addObserver(
      forName: .init("com.apple.screensaver.didstop"), object: nil, queue: nil
    ) { [weak self] _ in
      self?.update { $0.screensaverRunning = false }
    }
  }

  /// Runs `change` with `lock` held.
  private func update(_ change: (ScreenCaptureMonitor) -> Void) {
    lock.withLock { change(self) }
  }

}
