import Combine
import Foundation

/// Live density is memory-only. Persist at the end of a native gesture (or one
/// explicit button action), rather than writing preferences on every pinch frame.
@MainActor
final class DayTimelineZoomState: ObservableObject {
  static let storageKey = "dayTimelineZoomPercent"
  @Published private(set) var percent: Double
  let changes = PassthroughSubject<Double, Never>()
  private let defaults: UserDefaults

  init(defaults: UserDefaults = AppStoragePaths.defaults) {
    self.defaults = defaults
    // NSNumber accepts the previous integer percentages without a migration write.
    let stored = defaults.object(forKey: Self.storageKey) as? NSNumber
    percent = DayTimelineZoom.normalized(stored?.doubleValue ?? 100)
  }

  func setLive(_ value: Double) {
    let value = DayTimelineZoom.normalized(value)
    guard value != percent else { return }
    percent = value
    // Unlike @Published's willSet publisher, this is sent after the value changes,
    // so the synchronous AppKit render and SwiftUI content see the same density.
    changes.send(value)
  }

  func set(_ value: Double) {
    setLive(value)
    commit()
  }

  func commit() {
    defaults.set(percent, forKey: Self.storageKey)
  }
}
