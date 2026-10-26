import Foundation

enum TargetNotificationStyle: String, CaseIterable, Identifiable {
  case notch
  case notice

  var id: String { rawValue }

  var title: String {
    switch self {
    case .notch: return "刘海通知"
    case .notice: return "系统通知（Notice）"
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
    case .gemCollect: return "宝石收集 · Gem Collect"
    case .itemFound: return "发现物品 · Item Found"
    case .secretChime: return "秘密发现 · Secret Chime"
    case .ringChime: return "清脆铃声 · Ring Chime"
    case .itemFanfare: return "获得道具 · Item Fanfare"
    case .victoryFanfare: return "胜利号角 · Victory Fanfare"
    case .startupChime: return "启程提示 · Startup Chime"
    case .errorBuzz: return "错误警示 · Error Buzz"
    }
  }
}

extension TargetPreferences {
  static let notificationStyleKey = "target.notificationStyle"
  static let soundEnabledKey = "target.soundEnabled"
  static let reminderSoundKey = "target.reminderSound"

  static func notificationStyle(defaults: UserDefaults = .standard) -> TargetNotificationStyle {
    TargetNotificationStyle(rawValue: defaults.string(forKey: notificationStyleKey) ?? "") ?? .notch
  }

  static func soundEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: soundEnabledKey) as? Bool ?? true
  }

  static func reminderSound(defaults: UserDefaults = .standard) -> TargetReminderSound {
    TargetReminderSound(rawValue: defaults.string(forKey: reminderSoundKey) ?? "") ?? .gemCollect
  }
}
