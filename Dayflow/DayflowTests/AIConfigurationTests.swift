import XCTest
@testable import Dayflow

final class AIConfigurationTests: XCTestCase {
  private var suites: [String] = []

  override func tearDown() {
    for suite in suites { AppStoragePaths.defaults.removePersistentDomain(forName: suite) }
    super.tearDown()
  }

  func testOnlyActiveFeaturesAreConfigurableAndOldPipelineSettingIsIgnored() throws {
    XCTAssertEqual(AIFeature.configurableCases, [.timeline, .targetEvaluation])
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AIConfiguration())) as? [String: Any])
    legacy["timelinePipeline"] = "staged"
    let restored = try JSONDecoder().decode(AIConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
    XCTAssertNil(encoded["timelinePipeline"])
  }

  func testLocalCredentialsPersistWithPrivatePermissionsAndNeverResurrectAfterDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var migrations = 0
    let store = LocalProviderCredentialStore(directory: directory, legacyRead: { _ in
      migrations += 1
      return "legacy-test-key"
    })
    XCTAssertEqual(store.retrieve(for: "connection"), "legacy-test-key")
    XCTAssertEqual(store.retrieve(for: "connection"), "legacy-test-key")
    XCTAssertEqual(migrations, 1)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(files.first).path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertTrue(store.store("replacement-test-key", for: "connection"))
    let reopened = LocalProviderCredentialStore(directory: directory, legacyRead: { _ in
      XCTFail("Existing local credentials must not access Keychain")
      return nil
    })
    XCTAssertEqual(reopened.retrieve(for: "connection"), "replacement-test-key")
    XCTAssertTrue(reopened.delete(for: "connection"))
    XCTAssertNil(reopened.retrieve(for: "connection"))
  }

  func testUnavailableLegacyCredentialIsOnlyCheckedOnce() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var attempts = 0
    let store = LocalProviderCredentialStore(directory: directory, legacyRead: { _ in attempts += 1; return nil })
    XCTAssertNil(store.retrieve(for: "missing"))
    XCTAssertNil(store.retrieve(for: "missing"))
    XCTAssertEqual(attempts, 1)
  }

  func testRoundTripPreservesMultipleConnectionsAndOrderedCrossConnectionFallbacks() throws {
    let defaults = try makeDefaults()
    let first = AIProviderConnection(name: "Subscription", kind: .codexCLI)
    let second = AIProviderConnection(name: "Relay", kind: .openAICompatible, endpoint: "https://example.com/v1")
    let primary = AIModelAssignment(connectionID: first.id, modelID: "exact-model", effort: "high")
    let fallback = AIModelAssignment(connectionID: second.id, modelID: "relay/model")
    let value = AIConfiguration(connections: [first, second], routes: [
      .timeline: AIFeatureRoute(primary: primary, fallbacks: [fallback]),
      .targetEvaluation: AIFeatureRoute(primary: fallback),
    ])
    let store = makeStore(defaults)
    try store.save(value)
    XCTAssertEqual(try store.load(), value)
    XCTAssertEqual(try store.load().selection(for: fallback).connection.id, second.id)
  }

  func testMigrationPreservesOverridesFallbacksAndStableIDsWithoutRewritingLegacyValues() throws {
    let defaults = try makeDefaults()
    let oldRouting = LLMProviderRouting(primary: .chatGPT, secondary: .claude)
    let routingData = try JSONEncoder().encode(oldRouting)
    defaults.set(routingData, forKey: LLMProviderRoutingStore.storageKey)
    var preferences = ModelPreferences()
    preferences.defaultSelection = ModelOverride(model: "my-exact-model", reasoningEffort: .providerDefault)
    preferences.featureOverrides[.timeline] = ModelOverride(model: "timeline-model", reasoningEffort: .high)
    preferences.fallbackModels = ["fallback-a", "fallback-b"]
    let preferencesData = try JSONEncoder().encode(preferences)
    defaults.set(preferencesData, forKey: ModelPreferences.storageKey(for: .chatGPT))
    let store = makeStore(defaults)
    let first = try store.load()
    let route = try XCTUnwrap(first.routes[.timeline])
    XCTAssertEqual(route.primary.modelID, "timeline-model")
    XCTAssertEqual(route.primary.effort, "high")
    XCTAssertEqual(route.fallbacks.map(\.modelID), ["fallback-a", "fallback-b"])
    XCTAssertNil(first.routes[.text]?.primary.effort)
    XCTAssertNil(first.routes[.transcription])
    XCTAssertEqual(defaults.data(forKey: LLMProviderRoutingStore.storageKey), routingData)
    XCTAssertEqual(defaults.data(forKey: ModelPreferences.storageKey(for: .chatGPT)), preferencesData)
    defaults.set("local", forKey: "selectedLLMProvider")
    XCTAssertEqual(try store.load(), first)
    defaults.removeObject(forKey: AIConfigurationStore.storageKey)
    XCTAssertEqual(try store.load().connections.map(\.id), first.connections.map(\.id))
  }


  func testMigrationNeverInventsModelsOrEffortsForAnUnconfiguredCatalog() throws {
    let defaults = try makeDefaults()
    defaults.set(try JSONEncoder().encode(LLMProviderRouting(primary: .chatGPT)),
      forKey: LLMProviderRoutingStore.storageKey)
    let configuration = try makeStore(defaults).load()
    XCTAssertTrue(configuration.connections.allSatisfy { $0.models.isEmpty })
    XCTAssertTrue(configuration.routes.isEmpty)
    XCTAssertNil(configuration.defaultModel)
  }

  func testConnectionURLsCannotPersistCredentials() {
    for endpoint in ["https://user:password@example.com/v1", "https://example.com/v1?api_key=secret"] {
      let connection = AIProviderConnection(name: "Relay", kind: .openAICompatible, endpoint: endpoint)
      XCTAssertThrowsError(try AIConfiguration(connections: [connection]).validate()) {
        XCTAssertEqual($0 as? AIConfigurationError, .invalidEndpoint)
      }
    }
  }

  func testMigrationCopiesSecretToConnectionKeychainIDOnlyOnce() throws {
    let defaults = try makeDefaults()
    defaults.set(try JSONEncoder().encode(LLMProviderRouting(primary: .gemini)),
      forKey: LLMProviderRoutingStore.storageKey)
    var secrets = ["gemini": "private-key-value"]
    var writes = 0
    let store = AIConfigurationStore(defaults: defaults, readSecret: { secrets[$0] },
      writeSecret: { value, key in secrets[key] = value; writes += 1; return true },
      deleteSecret: { secrets.removeValue(forKey: $0); return true })
    let config = try store.load()
    let connection = try XCTUnwrap(config.connections.first(where: { $0.kind == .gemini }))
    XCTAssertEqual(store.secret(for: connection), "private-key-value")
    let data = try XCTUnwrap(defaults.data(forKey: AIConfigurationStore.storageKey))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-key-value"))
    _ = try store.load()
    XCTAssertEqual(writes, 1)
  }

  func testKeychainMigrationFailureLeavesConfigurationUnmigrated() throws {
    let defaults = try makeDefaults()
    let store = AIConfigurationStore(defaults: defaults,
      readSecret: { $0 == "gemini" ? "credential" : nil }, writeSecret: { _, _ in false })
    XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? AIConfigurationError, .credentialWriteFailed) }
    XCTAssertNil(defaults.object(forKey: AIConfigurationStore.storageKey))
  }

  func testCorruptSavedConfigurationIsNotOverwrittenByMigration() throws {
    let defaults = try makeDefaults()
    let corrupt = Data("invalid".utf8)
    defaults.set(corrupt, forKey: AIConfigurationStore.storageKey)
    XCTAssertThrowsError(try makeStore(defaults).load())
    XCTAssertEqual(defaults.data(forKey: AIConfigurationStore.storageKey), corrupt)
  }

  func testUnknownCapabilitiesAllowExplicitEffortButKnownCapabilitiesRejectIt() throws {
    var connection = AIProviderConnection(name: "Custom", kind: .openAICompatible,
      models: [AIConfiguredModel(id: "model")])
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "model", effort: "custom-effort")
    XCTAssertNoThrow(try AIConfiguration(connections: [connection]).selection(for: assignment))
    connection.models[0].reasoningChoices = ["low", "high"]
    XCTAssertThrowsError(try AIConfiguration(connections: [connection]).selection(for: assignment))
    connection.models[0].supportsReasoning = false
    let providerDefault = AIModelAssignment(connectionID: connection.id, modelID: "model")
    XCTAssertNoThrow(try AIConfiguration(connections: [connection]).selection(for: providerDefault))
  }

  func testDisabledConnectionRemainsSavedButCannotRun() throws {
    let connection = AIProviderConnection(name: "Paused", kind: .codexCLI, enabled: false)
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "model")
    let config = AIConfiguration(connections: [connection], routes: [.text: .init(primary: assignment)])
    XCTAssertNoThrow(try config.validate())
    XCTAssertThrowsError(try config.selection(for: assignment)) {
      XCTAssertEqual($0 as? AIConfigurationError, .disabledConnection)
    }
  }

  func testTaskLocalSelectionsStayIsolatedAcrossConcurrentRequests() async throws {
    let first = AIRuntimeSelection(connection: .init(name: "First", kind: .codexCLI), modelID: "a", effort: "high")
    let second = AIRuntimeSelection(connection: .init(name: "Second", kind: .claudeCLI), modelID: "b")
    async let a = AIRequestContext.$assignment.withValue(first) {
      await Task.yield()
      return AIRequestContext.assignment
    }
    async let b = AIRequestContext.$assignment.withValue(second) {
      await Task.yield()
      return AIRequestContext.assignment
    }
    let results = await (a, b)
    XCTAssertEqual(results.0, first)
    XCTAssertEqual(results.1, second)
    XCTAssertNil(AIRequestContext.assignment)
  }

  func testEffectiveAssignmentsUseOnlyPrimaryAndDefaultWithExactDeduplication() {
    let primary = AIModelAssignment(connectionID: UUID(), modelID: "model", effort: "low")
    let legacy = AIModelAssignment(connectionID: UUID(), modelID: "unused")
    var configuration = AIConfiguration(routes: [.timeline: .init(primary: primary, fallbacks: [legacy])], defaultModel: primary)
    XCTAssertEqual(configuration.assignments(for: .timeline), [primary])
    XCTAssertEqual(configuration.assignments(for: .text), [primary])
    var differentEffort = primary
    differentEffort.effort = "high"
    configuration.defaultModel = differentEffort
    XCTAssertEqual(configuration.assignments(for: .timeline), [primary, differentEffort])
    configuration.defaultModel = nil
    XCTAssertEqual(configuration.assignments(for: .text), [])
  }

  func testUnsetSplitStagesInheritDefaultIndependentlyFromTimelineOverride() {
    let timeline = AIModelAssignment(connectionID: UUID(), modelID: "timeline")
    let shared = AIModelAssignment(connectionID: UUID(), modelID: "shared")
    let cards = AIModelAssignment(connectionID: UUID(), modelID: "cards")
    let configuration = AIConfiguration(routes: [
      .timeline: .init(primary: timeline), .activityCards: .init(primary: cards)
    ], defaultModel: shared)
    XCTAssertEqual(configuration.assignments(for: .timeline), [timeline, shared])
    XCTAssertEqual(configuration.assignments(for: .transcription), [shared])
    XCTAssertEqual(configuration.assignments(for: .activityCards), [cards, shared])
  }

  func testOldStoredSchemaSeedsTimelineDefaultAndClearedDefaultStaysCleared() throws {
    let defaults = try makeDefaults()
    let connection = AIProviderConnection(name: "Existing", kind: .codexCLI)
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "model")
    let original = AIConfiguration(connections: [connection], routes: [.timeline: .init(primary: assignment)])
    let encoded = try JSONEncoder().encode(original)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "defaultModel")
    defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AIConfigurationStore.storageKey)
    let store = makeStore(defaults)
    var loaded = try store.load()
    XCTAssertEqual(loaded.defaultModel, assignment)
    XCTAssertEqual(loaded.assignments(for: .text), [assignment])
    loaded.defaultModel = nil
    try store.save(loaded)
    XCTAssertNil(try store.load().defaultModel)
    XCTAssertEqual(try store.load().assignments(for: .text), [])
    XCTAssertEqual(try store.load().routes[.timeline]?.primary, assignment)
  }

  func testIgnoredLegacyFallbackDoesNotInvalidateSavedConfiguration() throws {
    let connection = AIProviderConnection(name: "Existing", kind: .codexCLI)
    let assignment = AIModelAssignment(connectionID: connection.id, modelID: "model")
    let configuration = AIConfiguration(connections: [connection], routes: [
      .timeline: .init(primary: assignment, fallbacks: [.init(connectionID: UUID(), modelID: "")])
    ], defaultModel: assignment)
    XCTAssertNoThrow(try configuration.validate())
    var invalidDefault = configuration
    invalidDefault.defaultModel = .init(connectionID: UUID(), modelID: "missing")
    XCTAssertThrowsError(try invalidDefault.validate())
  }

  private func makeDefaults() throws -> UserDefaults {
    let suite = "AIConfigurationTests.\(UUID().uuidString)"
    suites.append(suite)
    return try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  private func makeStore(_ defaults: UserDefaults) -> AIConfigurationStore {
    AIConfigurationStore(defaults: defaults, readSecret: { _ in nil },
      writeSecret: { _, _ in true }, deleteSecret: { _ in true })
  }
}
