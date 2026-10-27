import XCTest
@testable import Dayflow

final class FlowConfiguredRoutingTests: XCTestCase {
  private func selection() -> AIRuntimeSelection {
    AIRuntimeSelection(
      connection: AIProviderConnection(
        name: "CLI", kind: .codexCLI,
        models: [AIConfiguredModel(id: "vision", supportsVision: true)]),
      modelID: "vision", effort: "low")
  }

  func testResumeRequiresSameConnectionModelAndEffort() {
    let original = selection()
    XCTAssertTrue(FlowDistractionAgent.canResume(previous: original, next: original))
    XCTAssertFalse(FlowDistractionAgent.canResume(previous: nil, next: original))
    var changed = original
    changed.connection.id = UUID()
    XCTAssertFalse(FlowDistractionAgent.canResume(previous: original, next: changed))
    changed = original
    changed.modelID = "other"
    XCTAssertFalse(FlowDistractionAgent.canResume(previous: original, next: changed))
    changed = original
    changed.effort = "high"
    XCTAssertFalse(FlowDistractionAgent.canResume(previous: original, next: changed))
    changed = original
    changed.connection.kind = .claudeCLI
    XCTAssertFalse(FlowDistractionAgent.canResume(previous: original, next: changed))
  }

  func testVisionCapabilityRejectsKnownTextOnlyModelsAndAllowsUnknownProbe() {
    var candidate = selection()
    XCTAssertTrue(FlowDistractionAgent.supportsConfiguredSelection(candidate))
    candidate.connection.models[0].supportsVision = false
    XCTAssertFalse(FlowDistractionAgent.supportsConfiguredSelection(candidate))
    candidate.connection.models[0].supportsVision = nil
    XCTAssertTrue(FlowDistractionAgent.supportsConfiguredSelection(candidate))
  }
}
