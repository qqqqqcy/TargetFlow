import XCTest
@testable import Dayflow

final class RetiredFeatureConfigurationTests: XCTestCase {
  func testOldRoutesAreIgnoredWithoutLosingTimelineOrDefaultModel() throws {
    let connection = AIProviderConnection(name: "Local", kind: .local,
      models: [AIConfiguredModel(id: "vision")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "vision")
    let route = AIFeatureRoute(primary: assignment)
    let original = AIConfiguration(connections: [connection], routes: [.timeline: route],
      defaultModel: assignment)
    var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    let routeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route))
    saved["routes"] = ["timeline", routeJSON, "chat", routeJSON, "dailyRecap", routeJSON,
      "flow", routeJSON, "targetEvaluation", routeJSON]
    let decoded = try JSONDecoder().decode(AIConfiguration.self,
      from: JSONSerialization.data(withJSONObject: saved))
    XCTAssertEqual(decoded.routes, [.timeline: route, .targetEvaluation: route])
    XCTAssertEqual(decoded.defaultModel, assignment)
    XCTAssertEqual(decoded.connections, [connection])
    XCTAssertNoThrow(try decoded.validate())
    XCTAssertEqual(try JSONDecoder().decode(AIConfiguration.self,
      from: JSONEncoder().encode(decoded)), decoded)
  }

  func testOldModelOverridesKeepActiveStages() throws {
    let data = Data(#"{"defaultSelection":{"model":"default"},"featureOverrides":["chat",{"model":"old-chat"},"flow",{"model":"old-flow"},"timeline",{"model":"vision"}],"fallbackModels":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(ModelPreferences.self, from: data)
    XCTAssertEqual(decoded.defaultSelection.model, "default")
    XCTAssertEqual(decoded.featureOverrides, [.timeline: ModelOverride(model: "vision")])
    XCTAssertEqual(decoded.fallbackModels, [])
  }
}
