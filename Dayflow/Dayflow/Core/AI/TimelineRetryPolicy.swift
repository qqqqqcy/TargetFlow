import Foundation

/// Keep transport recovery separate from repairing model output. The caller
/// owns a single attempt budget; neither decision starts another retry loop.
enum TimelineRetryPolicy {
  static let httpStatusKey = "TimelineHTTPStatus"
  static let retryAfterKey = "TimelineRetryAfter"

  static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError
      || ((error as NSError).domain == NSURLErrorDomain
        && (error as NSError).code == NSURLErrorCancelled)
  }

  static func isOutputFailure(_ error: Error) -> Bool {
    error is DecodingError || error is ClaudeOutputValidationError
      || error is TimelineNaturalMergeError
      || (error as NSError).domain == "OpenAICompatibleProvider"
  }

  /// Only bounded, recoverable transport failures are retried unchanged.
  /// Offline/permission, credentials, billing and malformed requests need a fix,
  /// not three copies of the same request with a JSON correction appended.
  static func transportDelay(for error: Error, attempt: Int) -> TimeInterval? {
    guard !isCancellation(error) else { return nil }
    let value = error as NSError
    if value.domain == NSURLErrorDomain {
      guard [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(value.code)
      else { return nil }
      return min(8, pow(2, Double(max(1, attempt))))
    }
    let status = value.userInfo[httpStatusKey] as? Int
    guard let status, [408, 429, 500, 502, 503, 504, 529].contains(status) else { return nil }
    let kind = TimelineFailureClassifier.classify(error).kind
    // A gateway may wrap a permanent account error in 429/503.
    guard [.transient, .unknown].contains(kind) else { return nil }
    let delay = value.userInfo[retryAfterKey] as? TimeInterval
      ?? min(8, pow(2, Double(max(1, attempt))))
    // Do not retry earlier than Retry-After or hold the entire queue for minutes.
    guard delay.isFinite, delay >= 0, delay <= 30 else { return nil }
    return delay
  }

  /// A bad reply affects one batch. An unavailable provider, cancellation or
  /// unknown failure stops the queue so dozens of independent batches do not
  /// all hit the same broken service.
  static func canContinueQueue(after error: Error) -> Bool {
    guard !isCancellation(error) else { return false }
    if (error as? TimelineCardReplacementError) == .timelineChanged { return true }
    if isOutputFailure(error) { return true }
    let kind = TimelineFailureClassifier.classify(error).kind
    return kind == .timelineMismatch || kind == .modelFlaky
  }

  static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
    guard let header else { return nil }
    if let seconds = TimeInterval(header), seconds.isFinite { return max(0, seconds) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
  }
}
