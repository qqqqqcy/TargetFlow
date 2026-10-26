import Foundation

extension Notification.Name {
  static let navigateToTarget = Notification.Name("navigateToTarget")
}

enum TargetPreferences {
  static let alertsEnabledKey = "target.alertsEnabled"
  static let cooldownMinutesKey = "target.cooldownMinutes"

  static func alertsEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: alertsEnabledKey) as? Bool ?? true
  }

  static func cooldownMinutes(defaults: UserDefaults = .standard) -> Int {
    let value = defaults.integer(forKey: cooldownMinutesKey)
    return [5, 15, 30].contains(value) ? value : 15
  }
}

struct FocusTarget: Codable, Equatable, Identifiable {
  let id: UUID
  let text: String
  let startedAt: Date
}

enum TargetAlignment: String, Codable, CaseIterable {
  case focused
  case neutral
  case severe

  var title: String {
    switch self {
    case .focused: return "专心"
    case .neutral: return "中性"
    case .severe: return "严重偏离"
    }
  }

  var symbol: String {
    switch self {
    case .focused: return "checkmark.circle"
    case .neutral: return "minus.circle"
    case .severe: return "exclamationmark.triangle"
    }
  }
}

struct TargetAssessment: Codable, Identifiable {
  var id: Int64 { cardID }
  let cardID: Int64
  let targetID: UUID
  let targetText: String
  let cardTitle: String
  let fingerprint: String
  let startTime: Date
  let endTime: Date
  let alignment: TargetAlignment
  let reason: String
  let reminder: String
}

struct TargetEvaluationResponse: Decodable {
  let alignment: TargetAlignment
  let reason: String
  let reminder: String

  static func parse(_ text: String) throws -> Self {
    // Providers sometimes wrap JSON in a Markdown fence.
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
      throw TargetEvaluationError.invalidResponse
    }
    let response = try JSONDecoder().decode(Self.self, from: Data(text[start...end].utf8))
    guard !response.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      response.reason.count <= 1000, response.reminder.count <= 500,
      response.alignment != .severe
        || !response.reminder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw TargetEvaluationError.invalidResponse }
    return response
  }
}

enum TargetEvaluationError: LocalizedError {
  case invalidResponse

  var errorDescription: String? { "AI 未返回有效的目标评估，请稍后重试。" }
}

enum TargetEvaluationPolicy {
  static func isEligible(endTime: Date, target: FocusTarget) -> Bool {
    endTime > target.startedAt
  }

  static func shouldNotify(
    alignment: TargetAlignment, endTime: Date, now: Date,
    lastReminderAt: Date?, cooldownMinutes: Int
  ) -> Bool {
    guard alignment == .severe,
      now.timeIntervalSince(endTime) >= -60,
      now.timeIntervalSince(endTime) <= 30 * 60
    else { return false }
    return lastReminderAt.map { now.timeIntervalSince($0) >= Double(cooldownMinutes * 60) } ?? true
  }
}
