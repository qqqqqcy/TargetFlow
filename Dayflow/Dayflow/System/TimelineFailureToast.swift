import Foundation

struct TimelineFailureToastPayload {
  let message: String
  let title: String?
  /// Provider the card is about, used to pick its logo.
  let providerName: String
  /// Plain-language fix steps; `command` is shown under the first one.
  let steps: [String]
  let command: String?
  /// How much recorded time is currently waiting to be turned into cards.
  let waitingSeconds: Int
  let destination: TimelineFailureToastDestination
  let failureKind: String
  let operation: String
  let primaryProvider: String
  let primaryProviderLabel: String
  let backupProvider: String?
  let backupProviderLabel: String?
  let backupConfigured: Bool
  let rateLimitDetected: Bool
  let errorDomain: String
  let errorCode: Int
  let batchId: Int64?

  var notificationUserInfo: [String: Any] {
    var userInfo: [String: Any] = [
      "message": message,
      "provider_name": providerName,
      "steps": steps,
      "waiting_seconds": waitingSeconds,
      "destination": destination.rawValue,
      "failure_kind": failureKind,
      "operation": operation,
      "primary_provider": primaryProvider,
      "primary_provider_label": primaryProviderLabel,
      "backup_configured": backupConfigured,
      "rate_limit_detected": rateLimitDetected,
      "error_domain": errorDomain,
      "error_code": errorCode,
    ]
    if let title {
      userInfo["title"] = title
    }
    if let command {
      userInfo["command"] = command
    }
    if let backupProvider {
      userInfo["backup_provider"] = backupProvider
    }
    if let backupProviderLabel {
      userInfo["backup_provider_label"] = backupProviderLabel
    }
    if let batchId {
      userInfo["batch_id"] = batchId
    }
    return userInfo
  }

  init(
    message: String,
    title: String?,
    providerName: String,
    steps: [String],
    command: String?,
    waitingSeconds: Int,
    destination: TimelineFailureToastDestination,
    failureKind: String,
    operation: String,
    primaryProvider: String,
    primaryProviderLabel: String,
    backupProvider: String?,
    backupProviderLabel: String?,
    backupConfigured: Bool,
    rateLimitDetected: Bool,
    errorDomain: String,
    errorCode: Int,
    batchId: Int64?
  ) {
    self.message = message
    self.title = title
    self.providerName = providerName
    self.steps = steps
    self.command = command
    self.waitingSeconds = waitingSeconds
    self.destination = destination
    self.failureKind = failureKind
    self.operation = operation
    self.primaryProvider = primaryProvider
    self.primaryProviderLabel = primaryProviderLabel
    self.backupProvider = backupProvider
    self.backupProviderLabel = backupProviderLabel
    self.backupConfigured = backupConfigured
    self.rateLimitDetected = rateLimitDetected
    self.errorDomain = errorDomain
    self.errorCode = errorCode
    self.batchId = batchId
  }

  init?(userInfo: [AnyHashable: Any]) {
    guard let message = userInfo["message"] as? String,
      let operation = userInfo["operation"] as? String,
      let primaryProvider = userInfo["primary_provider"] as? String,
      let backupConfigured = userInfo["backup_configured"] as? Bool,
      let rateLimitDetected = userInfo["rate_limit_detected"] as? Bool,
      let errorDomain = userInfo["error_domain"] as? String
    else {
      return nil
    }

    let title = userInfo["title"] as? String
    let providerName = userInfo["provider_name"] as? String ?? ""
    let steps = userInfo["steps"] as? [String] ?? []
    let command = userInfo["command"] as? String
    let waitingSeconds = (userInfo["waiting_seconds"] as? NSNumber)?.intValue ?? 0
    let destination =
      (userInfo["destination"] as? String)
      .flatMap(TimelineFailureToastDestination.init(rawValue:)) ?? .providers
    let failureKind = userInfo["failure_kind"] as? String ?? TimelineFailureKind.unknown.rawValue
    let primaryProviderLabel = (userInfo["primary_provider_label"] as? String) ?? primaryProvider
    let backupProvider = userInfo["backup_provider"] as? String
    let backupProviderLabel = userInfo["backup_provider_label"] as? String

    let errorCode: Int
    if let code = userInfo["error_code"] as? Int {
      errorCode = code
    } else if let number = userInfo["error_code"] as? NSNumber {
      errorCode = number.intValue
    } else {
      errorCode = 0
    }

    let batchId: Int64?
    if let id = userInfo["batch_id"] as? Int64 {
      batchId = id
    } else if let id = userInfo["batch_id"] as? Int {
      batchId = Int64(id)
    } else if let number = userInfo["batch_id"] as? NSNumber {
      batchId = number.int64Value
    } else {
      batchId = nil
    }

    self.init(
      message: message,
      title: title,
      providerName: providerName,
      steps: steps,
      command: command,
      waitingSeconds: waitingSeconds,
      destination: destination,
      failureKind: failureKind,
      operation: operation,
      primaryProvider: primaryProvider,
      primaryProviderLabel: primaryProviderLabel,
      backupProvider: backupProvider,
      backupProviderLabel: backupProviderLabel,
      backupConfigured: backupConfigured,
      rateLimitDetected: rateLimitDetected,
      errorDomain: errorDomain,
      errorCode: errorCode,
      batchId: batchId
    )
  }
}

enum TimelineFailureToastCenter {
  static func post(_ payload: TimelineFailureToastPayload) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: .showTimelineFailureToast,
        object: nil,
        userInfo: payload.notificationUserInfo
      )
    }
  }

  /// A batch just succeeded, so whatever the card asked the user to fix is fixed.
  static func hide() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .hideTimelineFailureToast, object: nil)
    }
  }
}
