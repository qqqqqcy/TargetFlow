import XCTest
@testable import Dayflow

final class AIConfiguredRuntimeTests: XCTestCase {
  private func connection(_ name: String = "Test") -> AIProviderConnection {
    AIProviderConnection(name: name, kind: .openAICompatible, endpoint: "https://example.com/v1", models: [.init(id: "model")])
  }

  func testFallbackOrderAndTaskLocalRestoration() async throws {
    let first = connection("First")
    let second = connection("Second")
    let runtime = AIConfiguredRuntime(configuration: .init(connections: [first, second], routes: [.text: .init(primary: .init(connectionID: first.id, modelID: "model", effort: "low"))], defaultModel: .init(connectionID: second.id, modelID: "model", effort: "high")), secret: { _ in nil })
    var visited: [UUID] = []
    let result = try await runtime.withConfiguration(feature: .text) { _ -> String in
      let selection = try XCTUnwrap(AIRequestContext.assignment)
      visited.append(selection.connection.id)
      if selection.connection.id == first.id {
        XCTAssertEqual(selection.effort, "low")
        throw AIConfiguredRuntimeError.invalidEndpoint
      }
      XCTAssertEqual(selection.effort, "high")
      return "success"
    }
    XCTAssertEqual(result, "success")
    XCTAssertEqual(visited, [first.id, second.id])
    XCTAssertNil(AIRequestContext.assignment)
  }

  func testCancellationDoesNotTryFallback() async throws {
    let first = connection()
    let second = connection()
    let runtime = AIConfiguredRuntime(configuration: .init(connections: [first, second], routes: [.text: .init(primary: .init(connectionID: first.id, modelID: "model"))], defaultModel: .init(connectionID: second.id, modelID: "model")), secret: { _ in nil })
    var attempts = 0
    do {
      let _: Void = try await runtime.withConfiguration(feature: .text) { _ in
        attempts += 1
        throw CancellationError()
      }
      XCTFail("Expected cancellation")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    XCTAssertEqual(attempts, 1)
    XCTAssertNil(AIRequestContext.assignment)
  }

  func testUnassignedFeatureInheritsDefault() async throws {
    let selected = connection()
    let assignment = AIModelAssignment(connectionID: selected.id, modelID: "model", effort: "low")
    let runtime = AIConfiguredRuntime(configuration: .init(connections: [selected], defaultModel: assignment))
    let result = try await runtime.withConfiguration(feature: .text) { _ in AIRequestContext.assignment }
    XCTAssertEqual(result?.connection.id, selected.id)
    XCTAssertEqual(result?.effort, "low")
    XCTAssertNil(AIRequestContext.assignment)
  }

  func testFailedIdenticalDefaultIsNotRetriedAndLegacyFallbackIsIgnored() async {
    let selected = connection()
    let assignment = AIModelAssignment(connectionID: selected.id, modelID: "model")
    let runtime = AIConfiguredRuntime(configuration: .init(connections: [selected], routes: [
      .text: .init(primary: assignment, fallbacks: [.init(connectionID: selected.id, modelID: "legacy")])
    ], defaultModel: assignment))
    var attempts = 0
    do {
      let _: Void = try await runtime.withConfiguration(feature: .text) { _ in
        attempts += 1
        throw AIConfiguredRuntimeError.invalidEndpoint
      }
      XCTFail("Expected failure")
    } catch {}
    XCTAssertEqual(attempts, 1)
  }

  func testInvalidFeatureSelectionFallsBackToDefault() async throws {
    let selected = connection()
    let runtime = AIConfiguredRuntime(configuration: .init(connections: [selected], routes: [
      .text: .init(primary: .init(connectionID: UUID(), modelID: "missing"))
    ], defaultModel: .init(connectionID: selected.id, modelID: "model")))
    let result = try await runtime.withConfiguration(feature: .text) { _ in AIRequestContext.assignment?.modelID }
    XCTAssertEqual(result, "model")
  }

  func testSecretLookupIsScopedToSelectedConnection() throws {
    let selected = AIProviderConnection(name: "Gemini", kind: .gemini, models: [.init(id: "custom-model")])
    var requested: [String] = []
    let runtime = AIConfiguredRuntime(configuration: .init(connections: [selected]), secret: {
      requested.append($0.secretKeyID)
      return "synthetic-test-key"
    })
    let provider = try runtime.makeProvider(for: .init(connection: selected, modelID: "custom-model"))
    guard case .gemini(let gemini) = provider else { return XCTFail("Wrong provider") }
    XCTAssertEqual(gemini.apiKey, "synthetic-test-key")
    XCTAssertEqual(requested, [selected.secretKeyID])
  }

  func testNoRouteDoesNotInventLegacyFallback() async {
    let runtime = AIConfiguredRuntime(configuration: .init(), secret: { _ in XCTFail("No credential should be read"); return nil })
    do {
      let _: Void = try await runtime.withConfiguration(feature: .text) { _ in XCTFail("Unexpected provider") }
      XCTFail("Expected missing route")
    } catch { XCTAssertTrue(error is AIConfiguredRuntimeError) }
  }

  func testSelectionUsesDomainEffortValidation() {
    let selected = AIProviderConnection(name: "Model", kind: .gemini, models: [.init(id: "model", reasoningChoices: ["low"], supportsReasoning: true)])
    let runtime = AIConfiguredRuntime(configuration: .init(connections: [selected]))
    XCTAssertThrowsError(try runtime.selection(for: .init(connectionID: selected.id, modelID: "model", effort: "high")))
    XCTAssertNoThrow(try runtime.selection(for: .init(connectionID: selected.id, modelID: "manually-entered-model")))
  }
}
