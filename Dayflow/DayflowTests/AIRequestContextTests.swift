import XCTest

@testable import Dayflow

final class AIRequestContextTests: XCTestCase {
  func testRuntimeAssignmentOverridesLegacyModelAndOmittedEffort() async throws {
    let connection = AIProviderConnection(
      name: "Configured subscription", kind: .codexCLI,
      models: [AIConfiguredModel(id: "selected-model", name: "Selected")])
    let selection = AIRuntimeSelection(connection: connection, modelID: "selected-model", effort: nil)
    await AIRequestContext.$assignment.withValue(selection) {
      let resolved = ModelPreferences.resolve(
        provider: .chatGPT, feature: .timeline,
        defaultModel: "legacy-model", defaultEffort: "high")
      XCTAssertEqual(resolved.model, "selected-model")
      XCTAssertNil(resolved.reasoningEffort)
      let timeline = CodexProvider.timelineModelConfiguration()
      XCTAssertEqual(timeline.model, "selected-model")
      XCTAssertNil(timeline.reasoningEffort)
    }
    XCTAssertNil(AIRequestContext.assignment)
  }

  func testGeminiForwardsProviderDefinedEffortWithoutModelNameHeuristics() throws {
    let connection = AIProviderConnection(name: "Gemini", kind: .gemini,
      models: [.init(id: "future-model", reasoningChoices: ["future-effort"])])
    let selection = AIRuntimeSelection(connection: connection, modelID: "future-model", effort: "future-effort")
    try AIRequestContext.$assignment.withValue(selection) {
      let result = try GeminiDirectProvider(apiKey: "test").thinkingConfig(feature: .timeline, model: "future-model")
      XCTAssertEqual(result?["thinkingLevel"] as? String, "future-effort")
    }
  }

  func testIndependentTasksKeepTheirAssignments() async {
    let connection = AIProviderConnection(name: "Test", kind: .codexCLI)
    await withTaskGroup(of: Void.self) { group in
      for model in ["first", "second", "third"] {
        group.addTask {
          await AIRequestContext.$assignment.withValue(
            AIRuntimeSelection(connection: connection, modelID: model, effort: "low")
          ) {
            await Task.yield()
            let resolved = CodexProvider.transcriptionModelConfiguration()
            XCTAssertEqual(resolved.model, model)
            XCTAssertEqual(resolved.reasoningEffort, "low")
          }
        }
      }
    }
  }
}
