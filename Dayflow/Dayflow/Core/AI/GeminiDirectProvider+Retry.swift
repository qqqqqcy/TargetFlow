import Foundation

extension GeminiDirectProvider {
  // MARK: - Error Classification for Unified Retry

  enum RetryStrategy {
    case immediate  // Parsing/encoding errors - retry immediately
    case shortBackoff  // Network timeouts - retry with 2s, 4s, 8s
    case longBackoff  // Rate limits - retry with 10s, 20s, 30s
    case enhancedPrompt  // Validation errors - retry with enhanced prompt
    case noRetry  // Auth/permanent errors - don't retry
  }

  func classifyError(_ error: Error) -> RetryStrategy {
    // JSON/Parsing errors - should retry immediately (different LLM response likely)
    if error is DecodingError {
      return .immediate
    }

    // Network/Transport errors
    if let nsError = error as NSError? {
      switch nsError.domain {
      case NSURLErrorDomain:
        switch nsError.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
          NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
          NSURLErrorNotConnectedToInternet:
          return .shortBackoff
        default:
          return .noRetry
        }

      case "GeminiError":
        switch nsError.code {
        // Rate limiting / high demand. These only reach here on the last model in the
        // chain, since earlier models switch to the next one instead of retrying.
        case 429, 503:
          return .longBackoff
        // Server errors
        case 500...599:
          return .shortBackoff
        // Auth errors
        case 401, 403:
          return .noRetry
        // Parsing/encoding errors
        case 7, 9, 10:
          return .immediate
        // Client errors (bad request, etc)
        case 400...499:
          return .noRetry
        default:
          return .shortBackoff
        }

      default:
        break
      }
    }

    // Default: short backoff for unknown errors
    return .shortBackoff
  }

  func delayForStrategy(_ strategy: RetryStrategy, attempt: Int) -> TimeInterval {
    switch strategy {
    case .immediate:
      return 0
    case .shortBackoff:
      return pow(2.0, Double(attempt)) * 2.0  // 2s, 4s, 8s
    case .longBackoff:
      return Double(min(30, (attempt + 1) * 10))  // 10s, 20s, 30s (capped)
    case .enhancedPrompt:
      return 1.0  // Brief delay for enhanced prompt
    case .noRetry:
      return 0
    }
  }
}
