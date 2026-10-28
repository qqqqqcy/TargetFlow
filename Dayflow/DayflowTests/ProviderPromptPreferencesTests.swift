import XCTest

@testable import Dayflow

final class ProviderPromptPreferencesTests: XCTestCase {
  private final class IgnoringUserDefaults: UserDefaults {
    var ignoredWriteKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
      guard !ignoredWriteKeys.contains(defaultName) else { return }
      super.set(value, forKey: defaultName)
    }
  }

  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      AppStoragePaths.defaults.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testChatGPTAndClaudeOverridesRoundTripIndependently() throws {
    let defaults = try makeDefaults()
    let chatGPT = ActivityCardPromptOverrides(
      titleBlock: "ChatGPT title",
      summaryBlock: "ChatGPT summary",
      detailedBlock: "ChatGPT details"
    )
    let claude = ActivityCardPromptOverrides(
      titleBlock: "Claude title",
      summaryBlock: "Claude summary",
      detailedBlock: "Claude details"
    )

    CodexPromptPreferences.save(chatGPT, to: defaults)
    ClaudePromptPreferences.save(claude, to: defaults)

    XCTAssertEqual(CodexPromptPreferences.load(from: defaults), chatGPT)
    XCTAssertEqual(ClaudePromptPreferences.load(from: defaults), claude)
  }

  func testResetOnlyClearsTheSelectedProviderPrompt() throws {
    let defaults = try makeDefaults()
    let chatGPT = ActivityCardPromptOverrides(titleBlock: "ChatGPT title")
    let claude = ActivityCardPromptOverrides(titleBlock: "Claude title")
    CodexPromptPreferences.save(chatGPT, to: defaults)
    ClaudePromptPreferences.save(claude, to: defaults)

    CodexPromptPreferences.reset(in: defaults)

    XCTAssertTrue(CodexPromptPreferences.load(from: defaults).isEmpty)
    XCTAssertEqual(ClaudePromptPreferences.load(from: defaults), claude)
  }

  func testCorruptProviderPromptFallsBackToDefaultsWithoutAffectingOtherProvider() throws {
    let defaults = try makeDefaults()
    let claude = ActivityCardPromptOverrides(titleBlock: "Claude title")
    defaults.set(Data("not-json".utf8), forKey: "chatGPTPromptOverrides")
    ClaudePromptPreferences.save(claude, to: defaults)

    XCTAssertTrue(CodexPromptPreferences.load(from: defaults).isEmpty)
    XCTAssertEqual(ClaudePromptPreferences.load(from: defaults), claude)
  }

  func testPromptSectionsUseOnlyTheProvidedProviderOverrides() {
    let chatGPT = ActivityCardPromptOverrides(
      titleBlock: "ChatGPT-only title",
      summaryBlock: nil,
      detailedBlock: nil
    )
    let claude = ActivityCardPromptOverrides(
      titleBlock: nil,
      summaryBlock: "Claude-only summary",
      detailedBlock: nil
    )

    let chatGPTSections = CodexPromptSections(overrides: chatGPT)
    let claudeSections = ClaudePromptSections(overrides: claude)

    XCTAssertEqual(chatGPTSections.title, "ChatGPT-only title")
    XCTAssertEqual(chatGPTSections.summary, CodexPromptDefaults.summaryBlock)
    XCTAssertEqual(claudeSections.title, ClaudePromptDefaults.titleBlock)
    XCTAssertEqual(claudeSections.summary, "Claude-only summary")
  }

  func testWhitespaceOnlyOverrideUsesProviderSpecificDefaultBlocks() {
    let overrides = ActivityCardPromptOverrides(
      titleBlock: "  \n  ",
      summaryBlock: "Custom summary",
      detailedBlock: nil
    )

    let codexSections = CodexPromptSections(overrides: overrides)
    let claudeSections = ClaudePromptSections(overrides: overrides)

    XCTAssertEqual(codexSections.title, CodexPromptDefaults.titleBlock)
    XCTAssertEqual(codexSections.summary, "Custom summary")
    XCTAssertEqual(codexSections.detailedSummary, CodexPromptDefaults.detailedSummaryBlock)
    XCTAssertEqual(claudeSections.title, ClaudePromptDefaults.titleBlock)
    XCTAssertEqual(claudeSections.summary, "Custom summary")
    XCTAssertEqual(claudeSections.detailedSummary, ClaudePromptDefaults.detailedSummaryBlock)
  }

  func testVerifiedSaveReportsAWriteThatDoesNotStick() throws {
    let defaults = try makeIgnoringDefaults()
    defaults.ignoredWriteKeys = ["chatGPTPromptOverrides"]
    let overrides = ActivityCardPromptOverrides(titleBlock: "ChatGPT title")

    XCTAssertThrowsError(
      try CodexPromptPreferences.saveVerified(overrides, to: defaults)
    ) { error in
      guard case ProviderPromptPreferencesError.writeVerificationFailed = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testMigrationPrefersConfiguredTimelineOverDefaultAndRetainsLegacyKeys() throws {
    let defaults = try makeDefaults()
    let codex = AIProviderConnection(name: "Codex", kind: .codexCLI)
    let gemini = AIProviderConnection(name: "Gemini", kind: .gemini)
    let configuration = AIConfiguration(
      connections: [codex, gemini],
      routes: [.timeline: .init(primary: .init(connectionID: gemini.id, modelID: "gemini"))],
      defaultModel: .init(connectionID: codex.id, modelID: "codex"))
    defaults.set(try JSONEncoder().encode(configuration), forKey: AIConfigurationStore.storageKey)
    CodexPromptPreferences.save(.init(titleBlock: "Codex legacy"), to: defaults)
    let expected = ActivityCardPromptOverrides(titleBlock: "Gemini legacy", detailedBlock: "Details")
    defaults.set(try JSONEncoder().encode(expected), forKey: "geminiPromptOverrides")
    XCTAssertEqual(ActivityCardPromptPreferences.load(from: defaults), expected)
    XCTAssertEqual(CodexPromptPreferences.load(from: defaults).titleBlock, "Codex legacy")
    XCTAssertNotNil(defaults.data(forKey: "geminiPromptOverrides"))
    try ActivityCardPromptPreferences.saveVerified(ActivityCardPromptOverrides(), to: defaults)
    XCTAssertTrue(ActivityCardPromptPreferences.load(from: defaults).isEmpty)
    XCTAssertNotNil(defaults.data(forKey: "geminiPromptOverrides"))
  }

  func testMigrationUsesConfiguredDefaultAndFallsBackDeterministically() throws {
    let defaults = try makeDefaults()
    let local = AIProviderConnection(name: "Local", kind: .local)
    defaults.set(try JSONEncoder().encode(AIConfiguration(
      connections: [local], defaultModel: .init(connectionID: local.id, modelID: "local"))),
      forKey: AIConfigurationStore.storageKey)
    CodexPromptPreferences.save(.init(titleBlock: "Codex legacy"), to: defaults)
    defaults.set(Data(#"{"summaryBlock":"Local summary"}"#.utf8),
      forKey: "ollamaPromptOverrides")
    XCTAssertEqual(ActivityCardPromptPreferences.load(from: defaults).summaryBlock, "Local summary")
    XCTAssertNil(ActivityCardPromptPreferences.load(from: defaults).titleBlock)

    let other = try makeDefaults()
    other.set(Data("invalid".utf8), forKey: "chatGPTPromptOverrides")
    ClaudePromptPreferences.save(.init(titleBlock: "Claude legacy"), to: other)
    XCTAssertEqual(ActivityCardPromptPreferences.load(from: other).titleBlock, "Claude legacy")
  }

  func testMigrationPreservesExplicitEmptyActiveProviderPreferences() throws {
    let defaults = try makeDefaults()
    let claude = AIProviderConnection(name: "Claude", kind: .claudeCLI)
    defaults.set(try JSONEncoder().encode(AIConfiguration(
      connections: [claude], defaultModel: .init(connectionID: claude.id, modelID: "sonnet"))),
      forKey: AIConfigurationStore.storageKey)
    ClaudePromptPreferences.save(.init(), to: defaults)
    CodexPromptPreferences.save(.init(titleBlock: "Inactive title"), to: defaults)
    XCTAssertTrue(ActivityCardPromptPreferences.load(from: defaults).isEmpty)
  }

  func testSharedWriteFailureIsReported() throws {
    let defaults = try makeIgnoringDefaults()
    defaults.ignoredWriteKeys = [ActivityCardPromptPreferences.storageKey]
    XCTAssertThrowsError(try ActivityCardPromptPreferences.saveVerified(.init(titleBlock: "Title"), to: defaults))
  }

  func testSharedSectionsReachGeminiAndLocalWithoutChangingTheirDefaults() {
    let overrides = ActivityCardPromptOverrides(
      titleBlock: "SHARED_TITLE", summaryBlock: "SHARED_SUMMARY", detailedBlock: "SHARED_DETAILS")
    let gemini = GeminiPromptSections(overrides: overrides)
    let local = OllamaPromptSections(overrides: overrides)
    XCTAssertTrue(gemini.title.contains("SHARED_TITLE"))
    XCTAssertTrue(gemini.summary.contains("SHARED_SUMMARY"))
    XCTAssertTrue(gemini.detailedSummary.contains("SHARED_DETAILS"))
    XCTAssertTrue(local.title.contains("SHARED_TITLE"))
    XCTAssertTrue(local.summary.contains("SHARED_SUMMARY"))
    XCTAssertTrue(local.detailedSummary.contains("SHARED_DETAILS"))
    XCTAssertEqual(GeminiPromptSections(overrides: .init()).title, GeminiPromptDefaults.titleBlock)
    XCTAssertEqual(OllamaPromptSections(overrides: .init()).title, OllamaPromptDefaults.titleBlock)
    XCTAssertTrue(overrides.instructionBlock.contains("Preserve the required output schema"))
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "ProviderPromptPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  private func makeIgnoringDefaults() throws -> IgnoringUserDefaults {
    let suiteName = "ProviderPromptPreferencesTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(IgnoringUserDefaults(suiteName: suiteName))
  }
}
