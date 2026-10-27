import AppKit
import XCTest
@testable import Dayflow

@MainActor
final class AIConfigurationValidatorTests: XCTestCase {
  private func configuration() -> AIConfiguration {
    let connection = AIProviderConnection(name: "Fixture", kind: .openAICompatible, endpoint: "https://example.com/v1", models: [.init(id: "first"), .init(id: "second")])
    return .init(connections: [connection], routes: [.targetEvaluation: .init(primary: .init(connectionID: connection.id, modelID: "first"), fallbacks: [.init(connectionID: connection.id, modelID: "legacy-unused")])], defaultModel: .init(connectionID: connection.id, modelID: "second"))
  }

  func testChecksAllFeaturesWithEffectiveModelsIgnoringLegacyFallbacks() async {
    var checked: [String] = []
    let validator = AIConfigurationValidator(probe: { _, feature, selection in
      XCTAssertEqual(selection.modelID, feature == .targetEvaluation ? "first" : "second")
      checked.append(selection.modelID)
      if selection.modelID == "first" { throw AIValidationContentError.invalidJSON }
    })
    await validator.validate(configuration: configuration())
    XCTAssertEqual(checked, ["second", "first"])
    XCTAssertEqual(validator.results.map(\.position), [0, 0])
    XCTAssertEqual(validator.results.map(\.feature), AIFeature.configurableCases)
    XCTAssertEqual(validator.results.map(\.status), [.passed, .failed])
    XCTAssertFalse(validator.running)
  }

  func testHiddenRoutesArePreservedButNotProbed() async {
    var configuration = configuration()
    let assignment = configuration.defaultModel!
    configuration.routes[.chat] = .init(primary: assignment)
    configuration.routes[.flow] = .init(primary: assignment)
    configuration.routes[.dailyRecap] = .init(primary: assignment)
    configuration.routes[.text] = .init(primary: assignment)
    let validator = AIConfigurationValidator(probe: { _, _, _ in })
    await validator.validate(configuration: configuration)
    XCTAssertEqual(validator.results.map(\.feature), AIFeature.configurableCases)
    XCTAssertEqual(configuration.routes.count, 5)
  }

  func testMissingDefaultStillReportsEveryUnassignedFeatureAsFailed() async {
    var configuration = configuration()
    configuration.defaultModel = nil
    var probed: [AIFeature] = []
    let validator = AIConfigurationValidator(probe: { _, feature, _ in probed.append(feature) })
    await validator.validate(configuration: configuration)
    XCTAssertEqual(validator.results.map(\.feature), AIFeature.configurableCases)
    XCTAssertEqual(validator.results.map(\.status), [.failed, .passed])
    XCTAssertEqual(probed, [.targetEvaluation])
    XCTAssertTrue(validator.results.prefix(1).allSatisfy {
      $0.reason == AIConfiguredRuntimeError.missingRoute.localizedDescription
    })
  }

  func testErrorTextDoesNotLeakProviderSecrets() async {
    let validator = AIConfigurationValidator(probe: { _, _, _ in
      throw NSError(domain: "Provider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unauthorized api-key=secret-test-value https://example.com/?key=secret-test-value"])
    })
    await validator.validate(configuration: configuration())
    XCTAssertTrue(validator.results.allSatisfy { $0.status == .failed })
    XCTAssertTrue(validator.results.allSatisfy { !$0.reason.contains("secret-test-value") && !$0.reason.contains("https://") })
  }

  func testTimeoutAndInvalidate() async {
    let validator = AIConfigurationValidator(timeoutSeconds: 0.01, probe: { _, _, _ in
      try await Task.sleep(nanoseconds: 5_000_000_000)
    })
    await validator.validate(configuration: configuration())
    XCTAssertTrue(validator.results.allSatisfy { $0.status == .failed && $0.reason == AIConfiguredRuntimeError.timedOut.localizedDescription })
    XCTAssertFalse(validator.running)
    validator.invalidate()
    XCTAssertTrue(validator.results.isEmpty)
  }

  func testExplicitCancellationStopsRun() async {
    let validator = AIConfigurationValidator(probe: { _, _, _ in
      try await Task.sleep(nanoseconds: 5_000_000_000)
    })
    let work = Task { await validator.validate(configuration: configuration()) }
    await Task.yield()
    validator.cancel()
    await work.value
    XCTAssertFalse(validator.running)
    XCTAssertTrue(validator.results.allSatisfy { $0.status == .cancelled })
  }

  func testSyntheticImageIsReadableAndVisionPromptDoesNotSupplyMarker() throws {
    let fixture = try AIValidationFixture()
    defer { fixture.remove() }
    let image = try XCTUnwrap(NSImage(contentsOf: fixture.imageURL))
    XCTAssertGreaterThanOrEqual(image.size.width, 900)
    XCTAssertGreaterThanOrEqual(image.size.height, 500)
    XCTAssertEqual(fixture.screenshots.count, 2)
    XCTAssertEqual(fixture.screenshots.last!.capturedAt - fixture.screenshots.first!.capturedAt, 900)
    XCTAssertFalse(fixture.context.batchObservations.map(\.observation).joined().contains(AIValidationFixture.imageMarker))
  }

  func testContentValidationRejectsHTTPStyleSuccessAndWrongSchema() throws {
    XCTAssertThrowsError(try AIValidationFixture.checkJSON("OK", expected: AIValidationFixture.contextMarker, feature: .text))
    XCTAssertThrowsError(try AIValidationFixture.checkJSON("{\"answer\":\"wrong marker\"}", expected: AIValidationFixture.contextMarker, feature: .text))
    XCTAssertNoThrow(try AIValidationFixture.checkJSON("{\"answer\":\"DAYFLOW CONTEXT 8316\"}", expected: AIValidationFixture.contextMarker, feature: .chat))
    XCTAssertThrowsError(try AIValidationFixture.checkJSON("{\"summary\":\"DAYFLOW CONTEXT 8316\",\"highlights\":[\"report\"]}", expected: AIValidationFixture.contextMarker, feature: .dailyRecap))
    XCTAssertNoThrow(try AIValidationFixture.checkJSON("{\"done\":[\"Finished DAYFLOW CONTEXT 8316\"],\"next\":null}", expected: AIValidationFixture.contextMarker, feature: .dailyRecap))
    XCTAssertNoThrow(try AIValidationFixture.checkJSON("{\"alignment\":\"focused\",\"reason\":\"Completed DAYFLOW CONTEXT 8316\",\"reminder\":\"\"}", expected: AIValidationFixture.contextMarker, feature: .targetEvaluation))
    XCTAssertThrowsError(try AIValidationFixture.checkJSON("{\"status\":\"on_task\",\"action\":\"none\",\"seeing\":\"wrong\",\"message\":\"\",\"reason\":\"\"}", expected: AIValidationFixture.imageMarker, feature: .flow))
  }
}
