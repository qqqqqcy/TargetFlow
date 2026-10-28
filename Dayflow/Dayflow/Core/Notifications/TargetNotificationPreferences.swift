import Foundation

enum TargetNotificationStyle: String, CaseIterable, Identifiable {
  case notch
  case notice

  var id: String { rawValue }

  var title: String {
    switch self {
    case .notch: return String(localized: "Notch notifications")
    case .notice: return String(localized: "System notifications (Notice)")
    }
  }
}

enum TargetReminderSound: String, CaseIterable, Identifiable {
  case gemCollect = "gem-collect"
  case itemFound = "item-found"
  case secretChime = "secret-chime"
  case ringChime = "ring-chime"
  case itemFanfare = "item-fanfare"
  case victoryFanfare = "victory-fanfare"
  case startupChime = "startup-chime"
  case errorBuzz = "error-buzz"

  var id: String { rawValue }
  var filename: String { "target-\(rawValue).caf" }
  var url: URL? { Bundle.main.url(forResource: "target-\(rawValue)", withExtension: "caf") }

  var title: String {
    switch self {
    case .gemCollect: return String(localized: "Gem Collect")
    case .itemFound: return String(localized: "Item Found")
    case .secretChime: return String(localized: "Secret Chime")
    case .ringChime: return String(localized: "Ring Chime")
    case .itemFanfare: return String(localized: "Item Fanfare")
    case .victoryFanfare: return String(localized: "Victory Fanfare")
    case .startupChime: return String(localized: "Startup Chime")
    case .errorBuzz: return String(localized: "Error Buzz")
    }
  }
}

extension TargetPreferences {
  static let notificationStyleKey = "target.notificationStyle"
  static let soundEnabledKey = "target.soundEnabled"
  static let reminderSoundKey = "target.reminderSound"

  static func notificationStyle(defaults: UserDefaults = AppStoragePaths.defaults) -> TargetNotificationStyle {
    TargetNotificationStyle(rawValue: defaults.string(forKey: notificationStyleKey) ?? "") ?? .notch
  }

  static func soundEnabled(defaults: UserDefaults = AppStoragePaths.defaults) -> Bool {
    defaults.object(forKey: soundEnabledKey) as? Bool ?? true
  }

  static func reminderSound(defaults: UserDefaults = AppStoragePaths.defaults) -> TargetReminderSound {
    TargetReminderSound(rawValue: defaults.string(forKey: reminderSoundKey) ?? "") ?? .gemCollect
  }
}
