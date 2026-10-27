import XCTest

@testable import Dayflow

final class CLIModelConfigurationTests: XCTestCase {
  func testProviderDefaultAppliesToAllCLIAnalysisPaths() throws {
    let name = "CLIModelConfigurationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    for provider in [LLMProviderID.chatGPT, .claude] {
      try ModelPreferences(
        defaultSelection: ModelOverride(model: "custom-model", reasoningEffort: .high)
      ).save(provider: provider, to: defaults)
    }
    let configurations = [
      CodexProvider.timelineModelConfiguration(defaults: defaults),
      CodexProvider.transcriptionModelConfiguration(defaults: defaults),
      CodexProvider.activityCardModelConfiguration(defaults: defaults),
      ClaudeProvider.timelineModelConfiguration(defaults: defaults),
      ClaudeProvider.transcriptionModelConfiguration(defaults: defaults),
      ClaudeProvider.activityCardModelConfiguration(defaults: defaults),
    ]
    for configuration in configurations {
      XCTAssertEqual(configuration.model, "custom-model")
      XCTAssertEqual(configuration.reasoningEffort, "high")
    }
  }

  func testFeatureCanOverrideModelAndLeaveEffortToCLI() throws {
    let name = "CLIModelConfigurationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try ModelPreferences(
      defaultSelection: ModelOverride(model: "global-model", reasoningEffort: .high),
      featureOverrides: [.timeline: ModelOverride(model: "timeline-model", reasoningEffort: .providerDefault)]
    ).save(provider: .chatGPT, to: defaults)
    let timeline = CodexProvider.timelineModelConfiguration(defaults: defaults)
    XCTAssertEqual(timeline.model, "timeline-model")
    XCTAssertNil(timeline.reasoningEffort)
    let cards = CodexProvider.activityCardModelConfiguration(defaults: defaults)
    XCTAssertEqual(cards.model, "global-model")
    XCTAssertEqual(cards.reasoningEffort, "high")
  }
}
