import XCTest

@testable import Dayflow

final class ModelPreferencesTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for name in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: name)
    }
    suiteNames = []
    super.tearDown()
  }

  func testMissingPreferencesPreserveEveryCallerDefault() throws {
    let defaults = try makeDefaults()
    for feature in ModelFeature.allCases {
      XCTAssertEqual(
        ModelPreferences.resolve(
          provider: .chatGPT, feature: feature, defaultModel: "legacy-\(feature.rawValue)",
          defaultEffort: "high", defaults: defaults),
        ModelSelection(model: "legacy-\(feature.rawValue)", reasoningEffort: "high"))
    }
    XCTAssertNil(ModelPreferences.load(provider: .chatGPT, from: defaults).fallbackModels)
  }

  func testFeatureAndGlobalOverridesResolveFieldsIndependently() throws {
    let defaults = try makeDefaults()
    let preferences = ModelPreferences(
      defaultSelection: ModelOverride(model: "global", reasoningEffort: .medium),
      featureOverrides: [
        .chat: ModelOverride(model: "chat"),
        .transcription: ModelOverride(reasoningEffort: .low),
      ])
    try preferences.save(provider: .chatGPT, to: defaults)

    XCTAssertEqual(resolve(.chat, defaults), ModelSelection(model: "chat", reasoningEffort: "medium"))
    XCTAssertEqual(resolve(.transcription, defaults), ModelSelection(model: "global", reasoningEffort: "low"))
    XCTAssertEqual(resolve(.flow, defaults), ModelSelection(model: "global", reasoningEffort: "medium"))
  }

  func testExplicitProviderDefaultOmitsEffortInsteadOfInheriting() throws {
    let defaults = try makeDefaults()
    var preferences = ModelPreferences(
      defaultSelection: ModelOverride(reasoningEffort: .providerDefault),
      featureOverrides: [.chat: ModelOverride(reasoningEffort: ModelReasoningEffort.none)])
    try preferences.save(provider: .chatGPT, to: defaults)
    XCTAssertNil(resolve(.text, defaults).reasoningEffort)
    XCTAssertEqual(resolve(.chat, defaults).reasoningEffort, "none")

    preferences.defaultSelection.reasoningEffort = .high
    preferences.featureOverrides[.chat] = ModelOverride(reasoningEffort: .providerDefault)
    try preferences.save(provider: .chatGPT, to: defaults)
    XCTAssertNil(resolve(.chat, defaults).reasoningEffort)
    preferences.featureOverrides.removeValue(forKey: .chat)
    try preferences.save(provider: .chatGPT, to: defaults)
    XCTAssertEqual(resolve(.chat, defaults).reasoningEffort, "high")
  }

  func testAllFeaturesAndProvidersRoundTripIndependently() throws {
    let defaults = try makeDefaults()
    let overrides = Dictionary(uniqueKeysWithValues: ModelFeature.allCases.map {
      ($0, ModelOverride(model: $0.rawValue, reasoningEffort: .providerDefault))
    })
    let expected = ModelPreferences(featureOverrides: overrides, fallbackModels: ["first", "second"])
    try expected.save(provider: .claude, to: defaults)
    try ModelPreferences(defaultSelection: ModelOverride(model: "codex")).save(
      provider: .chatGPT, to: defaults)
    XCTAssertEqual(ModelPreferences.load(provider: .claude, from: defaults), expected)
    XCTAssertEqual(ModelPreferences.load(provider: .chatGPT, from: defaults).defaultSelection.model, "codex")
    XCTAssertEqual(ModelPreferences.load(provider: .local, from: defaults), ModelPreferences())
  }

  func testFallbackStatesSurvivePersistenceAndCustomModelsAreNormalized() throws {
    let defaults = try makeDefaults()
    for models: [String]? in [nil, [], [" first ", "", "second", "first"]] {
      try ModelPreferences(fallbackModels: models).save(provider: .gemini, to: defaults)
      let expected: [String]? = models == nil ? nil : (models!.isEmpty ? [] : ["first", "second"])
      XCTAssertEqual(ModelPreferences.load(provider: .gemini, from: defaults).fallbackModels, expected)
    }
  }

  func testWhitespaceModelsInheritAndFreeEntryIsPreserved() throws {
    let defaults = try makeDefaults()
    var preferences = ModelPreferences(
      defaultSelection: ModelOverride(model: "  \n "),
      featureOverrides: [.chat: ModelOverride(model: " \n ")])
    try preferences.save(provider: .chatGPT, to: defaults)
    XCTAssertEqual(resolve(.chat, defaults).model, "legacy")
    preferences.featureOverrides[.chat]?.model = " vendor/future-model:custom "
    try preferences.save(provider: .chatGPT, to: defaults)
    XCTAssertEqual(resolve(.chat, defaults).model, "vendor/future-model:custom")
  }

  func testInvalidEffortOrMultilineModelDoesNotReplaceSavedPreferences() throws {
    let defaults = try makeDefaults()
    let original = ModelPreferences(defaultSelection: ModelOverride(model: "sonnet"))
    try original.save(provider: .claude, to: defaults)
    XCTAssertThrowsError(
      try ModelPreferences(defaultSelection: ModelOverride(reasoningEffort: .minimal))
        .save(provider: .claude, to: defaults))
    XCTAssertThrowsError(
      try ModelPreferences(featureOverrides: [.chat: ModelOverride(model: "model\nother")])
        .save(provider: .claude, to: defaults))
    XCTAssertEqual(ModelPreferences.load(provider: .claude, from: defaults), original)
  }

  func testCorruptStorageIsIsolatedAndLoadDoesNotOverwriteIt() throws {
    let defaults = try makeDefaults()
    let corrupt = Data("invalid-json".utf8)
    defaults.set(corrupt, forKey: ModelPreferences.storageKey(for: .chatGPT))
    try ModelPreferences(defaultSelection: ModelOverride(model: "sonnet"))
      .save(provider: .claude, to: defaults)
    XCTAssertEqual(resolve(.chat, defaults), ModelSelection(model: "legacy", reasoningEffort: "high"))
    XCTAssertEqual(defaults.data(forKey: ModelPreferences.storageKey(for: .chatGPT)), corrupt)
    XCTAssertEqual(ModelPreferences.load(provider: .claude, from: defaults).defaultSelection.model, "sonnet")
  }

  func testUnsupportedPersistedEffortFallsBackToParent() throws {
    let defaults = try makeDefaults()
    let value = ModelPreferences(
      defaultSelection: ModelOverride(reasoningEffort: .low),
      featureOverrides: [.chat: ModelOverride(reasoningEffort: .minimal)])
    defaults.set(try JSONEncoder().encode(value), forKey: ModelPreferences.storageKey(for: .claude))
    let selection = ModelPreferences.resolve(
      provider: .claude, feature: .chat, defaultModel: "sonnet", defaultEffort: "high", defaults: defaults)
    XCTAssertEqual(selection.reasoningEffort, "low")
  }

  func testGeminiReasoningValidationUsesEffectiveModel() throws {
    let defaults = try makeDefaults()
    XCTAssertFalse(ModelReasoningEffort.choices(for: .gemini).contains(ModelReasoningEffort.none))
    XCTAssertEqual(ModelReasoningEffort.choices(for: .gemini, model: "gemini-2.5-flash"), [.providerDefault])
    XCTAssertEqual(ModelReasoningEffort.choices(for: .gemini, model: "gemini-3-pro"), [.providerDefault, .low, .high])
    XCTAssertThrowsError(
      try ModelPreferences(
        defaultSelection: ModelOverride(model: "gemini-3.8-flash", reasoningEffort: .medium),
        featureOverrides: [.chat: ModelOverride(model: "gemini-3-pro")])
        .save(provider: .gemini, to: defaults))
    XCTAssertNoThrow(
      try ModelPreferences(defaultSelection: ModelOverride(model: "gemini-3.8-flash", reasoningEffort: .minimal))
        .save(provider: .gemini, to: defaults))
  }

  func testSaveReportsIgnoredWrites() throws {
    let name = "ModelPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(name)
    let defaults = try XCTUnwrap(IgnoringUserDefaults(suiteName: name))
    XCTAssertThrowsError(
      try ModelPreferences(defaultSelection: ModelOverride(model: "custom"))
        .save(provider: .chatGPT, to: defaults))
  }

  private func resolve(_ feature: ModelFeature, _ defaults: UserDefaults) -> ModelSelection {
    ModelPreferences.resolve(
      provider: .chatGPT, feature: feature, defaultModel: "legacy", defaultEffort: "high", defaults: defaults)
  }

  private func makeDefaults() throws -> UserDefaults {
    let name = "ModelPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(name)
    return try XCTUnwrap(UserDefaults(suiteName: name))
  }

  private final class IgnoringUserDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {}
  }
}
