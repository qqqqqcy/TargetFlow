import XCTest

@testable import Dayflow

@MainActor
final class ProvidersSettingsViewModelTests: XCTestCase {
  private let defaultKeys = [
    "llmLocalEngine",
    "llmLocalBaseURL",
    "llmLocalModelId",
    "llmLocalAPIKey",
    "localSetupComplete",
    ActivityCardPromptPreferences.storageKey,
    AIConfigurationStore.storageKey,
    "geminiPromptOverrides",
    "ollamaPromptOverrides",
    "chatCLIPromptOverrides",
    "chatGPTPromptOverrides",
    "claudePromptOverrides",
    "dayflowProviderEndpointV2",
    "chatgptSetupComplete",
    "claudeSetupComplete",
    "geminiSelectedModel_v3",
    "geminiSelectedModel_v4",
    "geminiSelectedModel_v5",
    LLMProviderRoutingStore.storageKey,
  ]

  private var savedDefaults: [String: Any?] = [:]

  override func setUp() {
    super.setUp()
    savedDefaults = Dictionary(
      uniqueKeysWithValues: defaultKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    )
    defaultKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
  }

  override func tearDown() {
    defaultKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    for (key, value) in savedDefaults {
      if let value {
        UserDefaults.standard.set(value, forKey: key)
      }
    }
    savedDefaults = [:]
    super.tearDown()
  }

  func testCatalogAndRoutingRejectHostedProvider() throws {
    try LLMProviderRoutingStore.save(.init(primary: .local))
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()

    XCTAssertEqual(
      Set(viewModel.routingProviders.map(\.id)),
      Set([LLMProviderID.gemini, .chatGPT, .claude, .openAICompatible, .local])
    )
    viewModel.beginProviderSetup(.dayflow, role: .primary)
    viewModel.editProviderConfiguration(.dayflow)
    XCTAssertNil(viewModel.setupModalProvider)
    XCTAssertFalse(viewModel.isProviderConfigured(.dayflow))
    XCTAssertFalse(viewModel.handleProviderSetupCompletion(.dayflow))
    XCTAssertFalse(viewModel.assignPrimaryProvider(.dayflow, requiresReadinessCheck: false))
    XCTAssertFalse(viewModel.assignSecondaryProvider(.dayflow, requiresReadinessCheck: false))
    XCTAssertEqual(viewModel.routing, .init(primary: .local))
  }

  func testProviderSetupCompletionRefreshesLocalModelSettingsFromDefaults() {
    UserDefaults.standard.set(LocalEngine.ollama.rawValue, forKey: "llmLocalEngine")
    UserDefaults.standard.set("http://localhost:11434", forKey: "llmLocalBaseURL")
    UserDefaults.standard.set("qwen2.5vl:7b", forKey: "llmLocalModelId")

    let viewModel = ProvidersSettingsViewModel()
    XCTAssertEqual(viewModel.localEngine, .ollama)
    XCTAssertEqual(viewModel.localModelId, "qwen2.5vl:7b")

    UserDefaults.standard.set(LocalEngine.lmstudio.rawValue, forKey: "llmLocalEngine")
    UserDefaults.standard.set("http://localhost:1234", forKey: "llmLocalBaseURL")
    UserDefaults.standard.set("gemma-4-local", forKey: "llmLocalModelId")
    UserDefaults.standard.set("local-test-key", forKey: "llmLocalAPIKey")

    viewModel.handleProviderSetupCompletion(.local)

    XCTAssertEqual(viewModel.localEngine, .lmstudio)
    XCTAssertEqual(viewModel.localBaseURL, "http://localhost:1234")
    XCTAssertEqual(viewModel.localModelId, "gemma-4-local")
    XCTAssertEqual(viewModel.localAPIKey, "local-test-key")
  }

  func testProviderSetupCompletionRefreshesGeminiModelPreference() {
    GeminiModelPreference(primary: .flash36).save()
    let viewModel = ProvidersSettingsViewModel()
    XCTAssertEqual(viewModel.selectedGeminiModel, .flash36)

    GeminiModelPreference(primary: .flashLite35).save()

    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.gemini))
    XCTAssertEqual(viewModel.selectedGeminiModel, .flashLite35)
  }

  func testGeminiModelPreferenceUsesTheNewFallbackChain() {
    XCTAssertEqual(GeminiModel.flash38.rawValue, "gemini-3.8-flash")
    XCTAssertEqual(GeminiModel.flash37.rawValue, "gemini-3.7-flash")
    XCTAssertEqual(
      GeminiModelPreference(primary: .flash37).orderedModels,
      [.flash37, .flash36, .flash35, .flashLite35]
    )
    XCTAssertEqual(GeminiModel.flash36.rawValue, "gemini-3.6-flash")
    XCTAssertEqual(GeminiModel.flash35.rawValue, "gemini-3.5-flash")
    XCTAssertEqual(GeminiModel.flashLite35.rawValue, "gemini-3.5-flash-lite")
    XCTAssertEqual(
      GeminiModelPreference.default.orderedModels,
      [.flash38, .flash37, .flash36, .flash35, .flashLite35]
    )
    XCTAssertEqual(
      GeminiModelPreference(primary: .flash35).orderedModels,
      [.flash35, .flashLite35]
    )
  }

  func testGeminiPreferencePreservesSavedSelectionAndDefaultsToFlash38() {
    XCTAssertEqual(GeminiModelPreference.load().primary, .flash38)
    GeminiModelPreference(primary: .flash36).save()
    XCTAssertEqual(GeminiModelPreference.load().orderedModels, [.flash36, .flash35, .flashLite35])
    GeminiModelPreference(primary: .flash38).save()
    XCTAssertEqual(GeminiModelPreference.load().primary, .flash38)
  }

  func testProviderSetupStateHydratesTheSavedLocalConfiguration() {
    UserDefaults.standard.set(LocalEngine.custom.rawValue, forKey: "llmLocalEngine")
    UserDefaults.standard.set("https://local.example.test/v1", forKey: "llmLocalBaseURL")
    UserDefaults.standard.set("saved-vision-model", forKey: "llmLocalModelId")
    UserDefaults.standard.set("saved-local-key", forKey: "llmLocalAPIKey")

    let state = ProviderSetupState()

    XCTAssertEqual(state.localEngine, .custom)
    XCTAssertEqual(state.localBaseURL, "https://local.example.test/v1")
    XCTAssertEqual(state.localModelId, "saved-vision-model")
    XCTAssertEqual(state.localAPIKey, "saved-local-key")
  }

  func testFailedSetupAssignmentRetainsRoutingIntentForRetry() throws {
    UserDefaults.standard.set(
      Data("corrupt-routing".utf8),
      forKey: LLMProviderRoutingStore.storageKey
    )
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()
    viewModel.beginProviderSetup(.claude, role: .primary)

    XCTAssertFalse(viewModel.handleProviderSetupCompletion(.claude))
    XCTAssertEqual(viewModel.setupModalProvider, .claude)

    UserDefaults.standard.removeObject(forKey: LLMProviderRoutingStore.storageKey)
    viewModel.loadRouting()

    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.claude))
    XCTAssertEqual(viewModel.primaryRoutingProviderId, .claude)
  }

  func testSharedEditorLoadsAndPersistsForEveryProvider() throws {
    try ActivityCardPromptPreferences.saveVerified(.init(titleBlock: "Shared title"))
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadSharedPromptOverridesIfNeeded()
    XCTAssertEqual(viewModel.titlePromptText, "Shared title")
    viewModel.useCustomSummaryPrompt = true
    viewModel.summaryPromptText = "Shared summary"
    viewModel.applyProviderChangeSideEffects(for: .openAICompatible)
    XCTAssertEqual(viewModel.titlePromptText, "Shared title")
    XCTAssertEqual(viewModel.summaryPromptText, "Shared summary")
    XCTAssertEqual(ActivityCardPromptPreferences.load().summaryBlock, "Shared summary")
  }

  func testResetSharedEditorDoesNotDeleteLegacyPreferences() throws {
    let legacy = ActivityCardPromptOverrides(titleBlock: "Legacy title")
    ClaudePromptPreferences.save(legacy)
    try ActivityCardPromptPreferences.saveVerified(.init(titleBlock: "Shared title"))
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadSharedPromptOverridesIfNeeded()
    viewModel.resetSharedPromptOverrides()
    XCTAssertFalse(viewModel.useCustomTitlePrompt)
    XCTAssertEqual(viewModel.titlePromptText, CodexPromptDefaults.titleBlock)
    XCTAssertTrue(ActivityCardPromptPreferences.load().isEmpty)
    XCTAssertEqual(ClaudePromptPreferences.load(), legacy)
  }
}
