import XCTest

@testable import Dayflow

final class SharedPromptLiveDeepSeekTests: XCTestCase {
  func testSharedPromptLiveDeepSeek() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["TARGETFLOW_LIVE_DEEPSEEK"] == "1"
      || environment["TEST_RUNNER_TARGETFLOW_LIVE_DEEPSEEK"] == "1" else {
      throw XCTSkip("Set TARGETFLOW_LIVE_DEEPSEEK=1 to run the authorized live validation.")
    }
    let data: Data
    if let path = environment["TARGETFLOW_LIVE_CONFIGURATION_PATH"]
      ?? environment["TEST_RUNNER_TARGETFLOW_LIVE_CONFIGURATION_PATH"] {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } else {
      let appDefaults = try XCTUnwrap(UserDefaults(suiteName: "local.targetflow.app"))
      data = try XCTUnwrap(appDefaults.data(forKey: AIConfigurationStore.storageKey))
    }
    let configuration = try JSONDecoder().decode(AIConfiguration.self, from: data)
    let connection = try XCTUnwrap(configuration.connections.first {
      $0.enabled && $0.kind == .openAICompatible
        && URL(string: $0.endpoint ?? "")?.host?.lowercased().contains("deepseek") == true
    })
    let model = try XCTUnwrap(connection.models.first { $0.supportsVision != true } ?? connection.models.first)
    let selection = try configuration.selection(for: .init(connectionID: connection.id, modelID: model.id))
    let runtime = AIConfiguredRuntime(configuration: configuration)
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: ActivityCardPromptPreferences.storageKey)
    defer {
      if let previous { defaults.set(previous, forKey: ActivityCardPromptPreferences.storageKey) }
      else { defaults.removeObject(forKey: ActivityCardPromptPreferences.storageKey) }
    }
    let marker = "SHARED PROMPT VERIFIED"
    try ActivityCardPromptPreferences.saveVerified(.init(
      titleBlock: "For this validation, every card title must be exactly SHARED PROMPT VERIFIED."))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 13)))
    let observation = Observation(
      id: nil, batchId: 1, startTs: Int(start.timeIntervalSince1970),
      endTs: Int(start.timeIntervalSince1970) + 15 * 60,
      observation: "Edited release notes in a text editor for the entire fifteen-minute period.",
      metadata: nil, llmModel: nil, createdAt: nil)
    let context = ActivityGenerationContext(
      batchObservations: [observation], existingCards: [], currentTime: start.addingTimeInterval(900),
      categories: [], hasPreviousCardWithinFiveMinutes: false)
    let result = try await runtime.withSelection(selection) { provider in
      try await provider.generateActivityCards(observations: [observation], context: context, batchId: nil)
    }
    XCTAssertFalse(result.cards.isEmpty)
    XCTAssertTrue(result.cards.allSatisfy { $0.title == marker })
  }
}
