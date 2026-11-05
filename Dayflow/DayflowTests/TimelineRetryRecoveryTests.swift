import Foundation
import XCTest

@testable import Dayflow

final class TimelineRetryRecoveryTests: XCTestCase {
  private func http(_ status: Int, message: String = "Service unavailable",
    retryAfter: TimeInterval? = nil) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: message,
      TimelineRetryPolicy.httpStatusKey: status]
    if let retryAfter { info[TimelineRetryPolicy.retryAfterKey] = retryAfter }
    return NSError(domain: "OllamaProvider", code: 4, userInfo: info)
  }

  func testOnlyRecoverableNetworkFailuresGetBoundedBackoff() {
    XCTAssertEqual(TimelineRetryPolicy.transportDelay(for: URLError(.timedOut), attempt: 1), 2)
    XCTAssertEqual(TimelineRetryPolicy.transportDelay(for: URLError(.networkConnectionLost), attempt: 2), 4)
    for code: URLError.Code in [.notConnectedToInternet, .cancelled, .userAuthenticationRequired,
      .serverCertificateUntrusted, .badURL] {
      XCTAssertNil(TimelineRetryPolicy.transportDelay(for: URLError(code), attempt: 1))
    }
    for status in [400, 401, 402, 403, 404, 413] {
      XCTAssertNil(TimelineRetryPolicy.transportDelay(for: http(status), attempt: 1))
    }
    for status in [408, 429, 500, 502, 503, 504, 529] {
      XCTAssertNotNil(TimelineRetryPolicy.transportDelay(for: http(status), attempt: 1))
    }
    XCTAssertNil(TimelineRetryPolicy.transportDelay(
      for: http(429, message: "Your account is not active, please check your billing details"), attempt: 1))
    XCTAssertEqual(TimelineRetryPolicy.transportDelay(for: http(503), attempt: 1), 2)
    XCTAssertEqual(TimelineRetryPolicy.transportDelay(for: http(503), attempt: 2), 4)
    XCTAssertEqual(TimelineRetryPolicy.transportDelay(for: http(429, retryAfter: 12), attempt: 1), 12)
    XCTAssertNil(TimelineRetryPolicy.transportDelay(for: http(429, retryAfter: 120), attempt: 1))
    XCTAssertEqual(TimelineRetryPolicy.retryAfter("7"), 7)
    let date = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(TimelineRetryPolicy.retryAfter("Thu, 01 Jan 1970 00:00:10 GMT", now: date), 10)
    XCTAssertNil(TimelineRetryPolicy.retryAfter("invalid"))
  }

  @MainActor
  func testTransportRetriesKeepOriginalPromptAndImagesWithoutCorrection() async throws {
    let fixture = try AIValidationFixture()
    defer { fixture.remove() }
    let bounds = TimelineOutputPolicy()
    let start = fixture.screenshots.first!.capturedAt / 60 * 60
    let end = fixture.screenshots.last!.capturedAt / 60 * 60 + 60
    let card = ActivityCardData(startTime: bounds.formatTimestampForPrompt(start),
      endTime: bounds.formatTimestampForPrompt(end), category: "Work", subcategory: "",
      title: "Synthetic event", summary: "Synthetic evidence", detailedSummary: "Evidence",
      distractions: nil, appSites: nil)
    let output = String(decoding: try JSONEncoder().encode([card]), as: UTF8.self)
    var requests: [Data] = []
    var delays: [TimeInterval] = []
    let config = OpenAICompatibleRuntimeConfiguration(configuration: .init(preset: .custom,
      baseURL: "https://synthetic.invalid/v1", modelID: "fixture"), bearerToken: nil)
    let provider = OpenAICompatibleProvider(configuration: config, sleep: { delays.append($0) }) { request, _, _ in
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      requests.append(try encoder.encode(request))
      if requests.count < 3 { throw URLError(.timedOut) }
      return output
    }
    let result = try await provider.generateTimeline(screenshots: fixture.screenshots,
      context: fixture.context, batchId: nil)
    XCTAssertEqual(result.cards.count, 1)
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(Set(requests).count, 1, "Network retry must not add a model correction")
    XCTAssertEqual(delays, [2, 4])
  }

  @MainActor
  func testInvalidHTTPEnvelopePausesQueueWithoutModelCorrection() async throws {
    for body in [#"{"error":{"message":"gateway failure"}}"#, #"{"choices":[]}"#] {
      let data = Data(body.utf8)
      var calls = 0
      let provider = OpenAICompatibleProvider(configuration: .init(configuration: .init(
        preset: .custom, baseURL: "https://synthetic.invalid/v1", modelID: "fixture"), bearerToken: nil),
        sleep: { _ in XCTFail("Protocol failure is not a model correction") }) { _, _, _ in
          calls += 1
          _ = try OllamaProvider.decodeChatResponse(data)
          XCTFail("Invalid envelope must not decode")
          return ""
        }
      do {
        _ = try await provider.generateActivityCards(observations: [], context: .init(
          batchObservations: [], existingCards: [], currentTime: Date(), categories: [],
          hasPreviousCardWithinFiveMinutes: false), batchId: nil)
        XCTFail("Must fail")
      } catch {
        XCTAssertTrue(error is OllamaProvider.ChatResponseDecodingError)
        XCTAssertFalse(TimelineRetryPolicy.isOutputFailure(error))
        XCTAssertFalse(TimelineRetryPolicy.canContinueQueue(after: error))
      }
      XCTAssertEqual(calls, 1)
    }
  }

  @MainActor
  func testPermanentErrorsAreNotRetriedOrSentAsModelCorrections() async throws {
    for error: Error in [http(401), http(413), http(429, message: "Your account is not active"),
      URLError(.notConnectedToInternet), URLError(.cancelled), CancellationError()] {
      var calls = 0
      let provider = OpenAICompatibleProvider(configuration: .init(configuration: .init(
        preset: .custom, baseURL: "https://synthetic.invalid/v1", modelID: "fixture"), bearerToken: nil),
        sleep: { _ in XCTFail("Permanent failures must not sleep/retry") }) { _, _, _ in
          calls += 1
          throw error
        }
      do {
        _ = try await provider.generateActivityCards(observations: [], context: .init(
          batchObservations: [], existingCards: [], currentTime: Date(), categories: [],
          hasPreviousCardWithinFiveMinutes: false), batchId: nil)
        XCTFail("Must preserve failure")
      } catch { XCTAssertEqual(calls, 1) }
    }
  }

  @MainActor
  func testNetworkAndJSONCorrectionShareOneThreeCallBudget() async throws {
    var calls = 0
    var prompts: [String] = []
    var delays: [TimeInterval] = []
    let provider = OpenAICompatibleProvider(configuration: .init(configuration: .init(
      preset: .custom, baseURL: "https://synthetic.invalid/v1", modelID: "fixture"), bearerToken: nil),
      sleep: { delays.append($0) }) { request, _, _ in
        calls += 1
        prompts.append(request.messages[1].content[0].text ?? "")
        if calls == 1 { throw URLError(.networkConnectionLost) }
        return "not JSON"
      }
    do {
      _ = try await provider.generateActivityCards(observations: [], context: .init(
        batchObservations: [], existingCards: [], currentTime: Date(), categories: [],
        hasPreviousCardWithinFiveMinutes: false), batchId: nil)
      XCTFail("Must reject malformed JSON")
    } catch { XCTAssertTrue(error is DecodingError) }
    XCTAssertEqual(calls, 3)
    XCTAssertEqual(prompts[0], prompts[1])
    XCTAssertTrue(prompts[2].contains("PREVIOUS ATTEMPT FAILED"))
    XCTAssertEqual(delays, [2, 2])
  }

  @MainActor
  func testFourteenBatchQueueContinuesAfterLocalContentFailureAndRefreshesIt() async {
    let done = expectation(description: "queue finished")
    var order: [Int64] = []
    var refreshed: [Int64] = []
    let coordinator = RetryCoordinator(batchIDsForDay: { _ in Array(1...14) },
      reprocess: { id, _, completion in
        order.append(id)
        if id == 1 { completion(.failure(ClaudeOutputValidationError.missingEvidenceCoverage)) }
        else { completion(.success(())) }
      }, setManualRetryRunning: { if !$0 { done.fulfill() } })
    coordinator.startRetry(for: "fixture") { refreshed.append($0) }
    await fulfillment(of: [done], timeout: 3)
    XCTAssertEqual(order, Array(1...14))
    XCTAssertEqual(refreshed, order, "Failed batch details must refresh too")
    XCTAssertEqual(coordinator.statuses[1], .failed)
    XCTAssertEqual(coordinator.statuses[14], .done)
    XCTAssertFalse(coordinator.isRunning)
  }

  @MainActor
  func testQueueStopsOnServiceFailureInsteadOfHittingAllFourteenBatches() async {
    for error: Error in [URLError(.timedOut), http(401), http(429), CancellationError()] {
      let done = expectation(description: "service failure stops queue")
      var order: [Int64] = []
      let coordinator = RetryCoordinator(batchIDsForDay: { _ in Array(1...14) },
        reprocess: { id, _, completion in order.append(id); completion(.failure(error)) },
        setManualRetryRunning: { if !$0 { done.fulfill() } })
      coordinator.startRetry(for: "fixture") { _ in }
      await fulfillment(of: [done], timeout: 3)
      XCTAssertEqual(order, [1])
      XCTAssertEqual(coordinator.statuses[1], .failed)
      XCTAssertEqual(coordinator.statuses[2], .stopped)
      XCTAssertFalse(coordinator.isRunning)
    }
  }

  private final class Eligibility: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int64] = [1, 2, 3]
    func read() -> [Int64] { lock.lock(); defer { lock.unlock() }; return ids }
    func remove(_ id: Int64) { lock.lock(); defer { lock.unlock() }; ids.removeAll { $0 == id } }
  }

  @MainActor
  func testQueueSkipsPlaceholderAlreadyReplacedWhileEarlierBatchWasRunning() async {
    let eligible = Eligibility()
    let done = expectation(description: "stale snapshot reconciled")
    var order: [Int64] = []
    let coordinator = RetryCoordinator(batchIDsForDay: { _ in eligible.read() },
      reprocess: { id, _, completion in
        order.append(id)
        if id == 1 { eligible.remove(2) }
        completion(.success(()))
      }, setManualRetryRunning: { if !$0 { done.fulfill() } })
    coordinator.startRetry(for: "fixture") { _ in }
    // A second click while running must not create another queue.
    coordinator.startRetry(for: "fixture") { _ in XCTFail("Duplicate queue") }
    await fulfillment(of: [done], timeout: 3)
    XCTAssertEqual(order, [1, 3])
    XCTAssertEqual(coordinator.statuses[2], .done)
  }
}
