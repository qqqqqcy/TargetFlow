import Foundation

/// How much new recording data to collect before updating timeline cards.
enum AnalysisPreferences {
  static let intervalKey = "timelineAnalysisIntervalSeconds"
  static let intervalOptions: [TimeInterval] = [60, 300, 900]
  static let defaultInterval: TimeInterval = 300

  static var interval: TimeInterval {
    get { interval(in: .standard) }
    set { setInterval(newValue, in: .standard) }
  }

  static func interval(in defaults: UserDefaults) -> TimeInterval {
    let stored = defaults.double(forKey: intervalKey)
    return intervalOptions.contains(stored) ? stored : defaultInterval
  }

  static func setInterval(_ interval: TimeInterval, in defaults: UserDefaults) {
    guard intervalOptions.contains(interval) else { return }
    defaults.set(interval, forKey: intervalKey)
  }

  static func label(for interval: TimeInterval) -> String {
    String(localized: "Every \(Int(interval / 60)) min")
  }
}
