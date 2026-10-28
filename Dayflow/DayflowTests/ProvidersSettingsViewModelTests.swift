import XCTest

@testable import Dayflow

@MainActor
final class ProvidersSettingsViewModelTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "ProvidersSettingsViewModelTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  func testCLISetupUsesCurrentConnectionEditorWithoutChangingLegacyRouting() throws {
    let previousRouting = defaults.object(forKey: LLMProviderRoutingStore.storageKey)
    let viewModel = ProvidersSettingsViewModel(defaults: defaults)
    viewModel.editProviderConfiguration(.local)
    XCTAssertNil(viewModel.setupModalProvider)
    viewModel.editProviderConfiguration(.claude)
    XCTAssertEqual(viewModel.setupModalProvider, .claude)
    XCTAssertFalse(viewModel.handleProviderSetupCompletion(.local))
    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.claude))
    // The setup screen allows switching between Codex and Claude before completion.
    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.chatGPT))
    viewModel.cancelProviderSetup()
    XCTAssertNil(viewModel.setupModalProvider)
    XCTAssertFalse(viewModel.handleProviderSetupCompletion(.claude))
    XCTAssertEqual(defaults.object(forKey: LLMProviderRoutingStore.storageKey) as? Data,
      previousRouting as? Data)
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
    XCTAssertEqual(GeminiModelPreference.load(from: defaults).primary, .flash38)
    GeminiModelPreference(primary: .flash36).save(to: defaults)
    XCTAssertEqual(GeminiModelPreference.load(from: defaults).orderedModels, [.flash36, .flash35, .flashLite35])
    GeminiModelPreference(primary: .flash38).save(to: defaults)
    XCTAssertEqual(GeminiModelPreference.load(from: defaults).primary, .flash38)
  }

  func testProviderSetupStateHydratesTheSavedLocalConfiguration() {
    defaults.set(LocalEngine.custom.rawValue, forKey: "llmLocalEngine")
    defaults.set("https://local.example.test/v1", forKey: "llmLocalBaseURL")
    defaults.set("saved-vision-model", forKey: "llmLocalModelId")
    defaults.set("saved-local-key", forKey: "llmLocalAPIKey")

    let state = ProviderSetupState(defaults: defaults)

    XCTAssertEqual(state.localEngine, .custom)
    XCTAssertEqual(state.localBaseURL, "https://local.example.test/v1")
    XCTAssertEqual(state.localModelId, "saved-vision-model")
    XCTAssertEqual(state.localAPIKey, "saved-local-key")
  }

  func testSharedEditorLoadsAndPersistsForEveryProvider() throws {
    try ActivityCardPromptPreferences.saveVerified(.init(titleBlock: "Shared title"), to: defaults)
    let viewModel = ProvidersSettingsViewModel(defaults: defaults)
    viewModel.loadSharedPromptOverridesIfNeeded()
    XCTAssertEqual(viewModel.titlePromptText, "Shared title")
    viewModel.useCustomSummaryPrompt = true
    viewModel.summaryPromptText = "Shared summary"
    viewModel.loadSharedPromptOverridesIfNeeded(force: true)
    XCTAssertEqual(viewModel.titlePromptText, "Shared title")
    XCTAssertEqual(viewModel.summaryPromptText, "Shared summary")
    XCTAssertEqual(ActivityCardPromptPreferences.load(from: defaults).summaryBlock, "Shared summary")
  }

  func testResetSharedEditorDoesNotDeleteLegacyPreferences() throws {
    let legacy = ActivityCardPromptOverrides(titleBlock: "Legacy title")
    ClaudePromptPreferences.save(legacy, to: defaults)
    try ActivityCardPromptPreferences.saveVerified(.init(titleBlock: "Shared title"), to: defaults)
    let viewModel = ProvidersSettingsViewModel(defaults: defaults)
    viewModel.loadSharedPromptOverridesIfNeeded()
    viewModel.resetSharedPromptOverrides()
    XCTAssertFalse(viewModel.useCustomTitlePrompt)
    XCTAssertEqual(viewModel.titlePromptText, CodexPromptDefaults.titleBlock)
    XCTAssertTrue(ActivityCardPromptPreferences.load(from: defaults).isEmpty)
    XCTAssertEqual(ClaudePromptPreferences.load(from: defaults), legacy)
  }
}
