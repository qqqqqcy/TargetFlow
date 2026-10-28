import Foundation

extension Notification.Name {
  static let navigateToEvents = Notification.Name("navigateToEvents")
}

enum TargetPreferences {
  static let alertsEnabledKey = "target.alertsEnabled"

  static func alertsEnabled(defaults: UserDefaults = AppStoragePaths.defaults) -> Bool {
    defaults.object(forKey: alertsEnabledKey) as? Bool ?? true
  }
}

struct FocusTarget: Codable, Equatable, Identifiable {
  let id: UUID
  let text: String
  let startedAt: Date
  var events: [FocusTargetEvent]? = nil
}

struct FocusTargetEvent: Codable, Equatable {
  let id: UUID
  let name: String
  let details: String
}

enum TargetAlignment: String, Codable, CaseIterable {
  case focused
  case neutral
  case severe

  var title: String {
    switch self {
    case .focused: return String(localized: "Focused")
    case .neutral: return String(localized: "Neutral")
    case .severe: return String(localized: "Distracted")
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
      response.alignment == .focused
        || !response.reminder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw TargetEvaluationError.invalidResponse }
    return response
  }
}

enum TargetEvaluationError: LocalizedError {
  case invalidResponse

  var errorDescription: String? { String(localized: "AI did not return a valid goal assessment. Please try again later.") }
}

enum TargetEvaluationPolicy {
  static func isEligible(endTime: Date, target: FocusTarget) -> Bool {
    endTime > target.startedAt
  }

  static func shouldNotify(
    alignment: TargetAlignment, endTime: Date, now: Date
  ) -> Bool {
    alignment != .focused
      && now.timeIntervalSince(endTime) >= -60
      && now.timeIntervalSince(endTime) <= 30 * 60
  }
}
