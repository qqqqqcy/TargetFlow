import Foundation
import CoreFoundation

/// Independent of how often timeline cards are generated.
enum InactivityPreferences {
  static let thresholdKey = "unchangedInactivityThresholdSeconds"
  static let thresholdOptions: [Int] = [300, 600, 900]
  static let defaultThreshold = 300

  static var thresholdSeconds: Int {
    get { thresholdSeconds(in: .standard) }
    set { setThresholdSeconds(newValue, in: .standard) }
  }

  static func thresholdSeconds(in defaults: UserDefaults) -> Int {
    // Do not coerce strings, booleans or fractional numbers into a valid setting.
    guard let value = defaults.object(forKey: thresholdKey) as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(),
      thresholdOptions.contains(where: { Double($0) == value.doubleValue })
    else { return defaultThreshold }
    return value.intValue
  }

  static func setThresholdSeconds(_ seconds: Int, in defaults: UserDefaults) {
    guard thresholdOptions.contains(seconds) else { return }
    defaults.set(seconds, forKey: thresholdKey)
  }

  static func label(for seconds: Int) -> String {
    String(localized: "\(seconds / 60) minutes")
  }
}
