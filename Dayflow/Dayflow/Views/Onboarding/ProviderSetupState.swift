import AppKit
import Foundation
import SwiftUI

class ProviderSetupState: ObservableObject {
  @Published var steps: [SetupStep] = []
  @Published var currentStepIndex: Int = 0
  @Published var apiKey: String = ""
  @Published private(set) var hasStoredGeminiAPIKey = false
  @Published var geminiAPIKeySaveError: String?
  @Published var saveErrorMessage: String?
  @Published var hasTestedConnection: Bool = false
  @Published var testSuccessful: Bool = false
  @Published var geminiModel: GeminiModel
  // Local engine configuration
  @Published var localEngine: LocalEngine
  @Published var localBaseURL: String
  @Published var localModelId: String
  @Published var localAPIKey: String
  @Published var openAICompatiblePreset: OpenAICompatiblePreset = .openRouter
  @Published var openAICompatibleBaseURL: String = OpenAICompatibleConfiguration.openRouterBaseURL
  @Published var openAICompatibleModelID: String = ""
  @Published var openAICompatibleAPIKey: String = ""
  // CLI detection
  @Published var codexCLIStatus: CLIDetectionState = .unknown
  @Published var claudeCLIStatus: CLIDetectionState = .unknown
  @Published var isCheckingCLIStatus: Bool = false
  @Published var codexCLIReport: CLIDetectionReport?
  @Published var claudeCLIReport: CLIDetectionReport?
  @Published var preferredCLITool: CLITool?

  var lastSavedGeminiModel: GeminiModel
  var hasStartedCLICheck = false
  @Published private(set) var configuredProviderID: LLMProviderID?

  init(defaults: UserDefaults = AppStoragePaths.defaults) {
    let savedLocalEngine =
      defaults.string(forKey: "llmLocalEngine").flatMap(LocalEngine.init(rawValue:)) ?? .lmstudio
    let savedLocalBaseURL =
      defaults.string(forKey: "llmLocalBaseURL")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let savedLocalModelID =
      defaults.string(forKey: "llmLocalModelId")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.localEngine = savedLocalEngine
    self.localBaseURL =
      savedLocalBaseURL.isEmpty
      ? savedLocalEngine.defaultBaseURL : savedLocalBaseURL
    self.localModelId =
      savedLocalModelID.isEmpty
      ? LocalModelPreferences.defaultModelId(for: savedLocalEngine) : savedLocalModelID
    self.localAPIKey = defaults.string(forKey: "llmLocalAPIKey") ?? ""

    let preference = GeminiModelPreference.load(from: defaults)
    self.geminiModel = preference.primary
    self.lastSavedGeminiModel = preference.primary
    self.preferredCLITool = nil

    if let configuration = OpenAICompatiblePreferences.load(from: defaults) {
      openAICompatiblePreset = configuration.preset
      openAICompatibleBaseURL = configuration.baseURL
      openAICompatibleModelID = configuration.modelID
    }
    openAICompatibleAPIKey =
      LocalProviderCredentialStore.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) ?? ""
  }

  var currentStep: SetupStep {
    guard currentStepIndex < steps.count else {
      return SetupStep(
        id: "fallback", title: String(localized: "Setup"),
        contentType: .information(
          String(localized: "Complete"), String(localized: "Setup is complete")))
    }
    return steps[currentStepIndex]
  }

  var canContinue: Bool {
    switch currentStep.contentType {
    case .apiKeyInput:
      let cleanedKey = apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
      return cleanedKey.count > 20 || (cleanedKey.isEmpty && hasStoredGeminiAPIKey)
    case .cliDetection:
      return isSelectedCLIToolReady
    case .information(_, _):
      if currentStep.id == "verify" || currentStep.id == "test" {
        return testSuccessful
      }
      return true
    case .localChoice, .localModelInstall, .apiKeyInstructions:
      return true
    }
  }

  var isLastStep: Bool {
    return currentStepIndex == steps.count - 1
  }

  func configureSteps(for provider: LLMProviderID) {
    configuredProviderID = provider
    switch provider {
    case .local:
      steps = [
        SetupStep(
          id: "intro",
          title: String(localized: "Before you begin"),
          contentType: .information(
            String(localized: "For experienced users"),
            String(
              localized:
                "This path is recommended only if you're comfortable running LLMs locally and debugging technical issues. If terms like vLLM or API endpoint don't ring a bell, we recommend going back and picking ChatGPT, Claude, or Gemini. It's non-technical and takes about 30 seconds.\n\nFor local mode, Target Flow recommends Qwen3-VL 4B as the core vision-language model (Qwen2.5-VL 3B remains available if you need a smaller download)."
            )
          )
        ),
        SetupStep(
          id: "choose", title: String(localized: "Choose engine"), contentType: .localChoice),
        SetupStep(
          id: "model", title: String(localized: "Install model"), contentType: .localModelInstall),
        SetupStep(
          id: "test", title: String(localized: "Test connection"),
          contentType: .information(
            String(localized: "Test Connection"),
            String(
              localized:
                "Click the button below to verify your local server responds to a simple chat completion."
            )
          )),
        SetupStep(
          id: "complete", title: String(localized: "Complete"),
          contentType: .information(
            String(localized: "All set!"),
            String(localized: "Local AI is configured and ready to use with Target Flow."))),
      ]
    case .chatGPT, .claude:
      preferredCLITool = provider == .claude ? .claude : .codex
      steps = chatCLISteps(for: provider)
      codexCLIStatus = .unknown
      claudeCLIStatus = .unknown
      codexCLIReport = nil
      claudeCLIReport = nil
      isCheckingCLIStatus = false
      hasStartedCLICheck = false
    case .openAICompatible:
      steps = [
        SetupStep(
          id: "intro",
          title: String(localized: "Configure endpoint"),
          contentType: .information(
            String(localized: "Connect an OpenAI-compatible endpoint"),
            String(
              localized:
                "Use OpenRouter or another endpoint that supports OpenAI Chat Completions with image input. The connection test sends one image and may incur a small provider charge."
            )
          )
        ),
        SetupStep(
          id: "test",
          title: String(localized: "Test connection"),
          contentType: .information(
            String(localized: "Test Connection"),
            String(
              localized:
                "Enter the endpoint, model, and API key, then verify a multimodal response.")
          )
        ),
        SetupStep(
          id: "complete",
          title: String(localized: "Complete"),
          contentType: .information(
            String(localized: "All set!"),
            String(localized: "Your OpenAI-compatible provider is ready to use with Target Flow.")
          )
        ),
      ]
    case .gemini, .dayflow:
      let storedGeminiKey =
        LocalProviderCredentialStore.shared.retrieve(for: "gemini")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      hasStoredGeminiAPIKey = !storedGeminiKey.isEmpty
      steps = [
        SetupStep(
          id: "getkey", title: String(localized: "Get API key"),
          contentType: .apiKeyInstructions),
        SetupStep(
          id: "enterkey", title: String(localized: "Enter API key"),
          contentType: .apiKeyInput),
        SetupStep(
          id: "verify", title: String(localized: "Test connection"),
          contentType: .information(
            String(localized: "Test Connection"),
            String(localized: "Click the button below to verify your API key works with Gemini"))),
        SetupStep(
          id: "complete", title: String(localized: "Complete"),
          contentType: .information(
            String(localized: "All set!"),
            String(localized: "Gemini is now configured and ready to use with Target Flow."))),
      ]
    }
  }

  private func chatCLISteps(for provider: LLMProviderID) -> [SetupStep] {
    let isClaude = provider == .claude
    let providerName = isClaude ? "Claude" : "ChatGPT"
    let cliName = isClaude ? "Claude Code" : "Codex CLI"
    return [
      SetupStep(
        id: "intro",
        title: String(localized: "Before you begin"),
        contentType: .information(
          "",
          String(
            localized:
              "Target Flow uses \(cliName) through your existing \(providerName) subscription. Install it and sign in on this Mac, then we'll verify the connection."
          )
        )
      ),
      SetupStep(
        id: "detect",
        title: String(localized: "Check installations"),
        contentType: .cliDetection
      ),
      SetupStep(
        id: "test",
        title: String(localized: "Test connection"),
        contentType: .information(
          String(localized: "Test Connection"),
          String(localized: "Run a quick test to verify your CLI is working and signed in.")
        )
      ),
      SetupStep(
        id: "complete",
        title: String(localized: "Complete"),
        contentType: .information(
          String(localized: "All set!"),
          String(localized: "\(providerName) is configured and ready to use with Target Flow.")
        )
      ),
    ]
  }

  /// Swap the active chat-CLI provider mid-flow (e.g. user picked ChatGPT but selects
  /// Claude on the detection step). Rewrites the step copy in place without resetting
  /// detection results or the user's position in the flow.
  private func switchChatCLIProvider(to provider: LLMProviderID) {
    guard configuredProviderID == .chatGPT || configuredProviderID == .claude,
      provider == .chatGPT || provider == .claude,
      provider != configuredProviderID
    else { return }
    configuredProviderID = provider
    let refreshedSteps = chatCLISteps(for: provider)
    for (index, refreshed) in refreshedSteps.enumerated() where index < steps.count {
      var step = refreshed
      if steps[index].isCompleted {
        step.markCompleted()
      }
      steps[index] = step
    }
    // The connection test targets the selected CLI, so a switch invalidates it
    hasTestedConnection = false
    testSuccessful = false
  }

  func goNext() {
    if currentStepIndex < steps.count - 1 {
      currentStepIndex += 1
    }
  }

  func goBack() {
    if currentStepIndex > 0 {
      currentStepIndex -= 1
    }
  }

  func navigateToStep(_ stepId: String) {
    if let index = steps.firstIndex(where: { $0.id == stepId }) {
      // Reset test state when navigating to test step
      if stepId == "verify" || stepId == "test" {
        hasTestedConnection = false
        testSuccessful = false
      }
      // Allow free navigation between all steps
      currentStepIndex = index
    }
  }

  func markCurrentStepCompleted() {
    if currentStepIndex < steps.count {
      steps[currentStepIndex].markCompleted()
    }
  }

  func persistGeminiModelSelection() {
    guard geminiModel != lastSavedGeminiModel else { return }
    lastSavedGeminiModel = geminiModel

    // Changing models should prompt the user to re-run the connection test
    hasTestedConnection = false
    testSuccessful = false
  }

  func clearGeminiAPIKeySaveError() {
    geminiAPIKeySaveError = nil
  }

  var isSelectedCLIToolReady: Bool {
    guard let preferredCLITool else { return false }
    return isToolAvailable(preferredCLITool)
  }

  func ensureCLICheckStarted() {
    guard !hasStartedCLICheck else { return }
    hasStartedCLICheck = true
    refreshCLIStatuses()
  }

  func refreshCLIStatuses() {
    if isCheckingCLIStatus { return }
    isCheckingCLIStatus = true
    codexCLIStatus = .checking
    claudeCLIStatus = .checking
    codexCLIReport = nil
    claudeCLIReport = nil

    Task.detached { [weak self] in
      guard let self else { return }
      async let codex = CLIDetector.detect(tool: .codex)
      async let claude = CLIDetector.detect(tool: .claude)
      let (codexResult, claudeResult) = await (codex, claude)

      await MainActor.run {
        self.codexCLIReport = codexResult
        self.claudeCLIReport = claudeResult
        self.codexCLIStatus = codexResult.state
        self.claudeCLIStatus = claudeResult.state
        self.isCheckingCLIStatus = false
        self.ensurePreferredCLIToolIsValid()
      }
    }
  }

  func selectPreferredCLITool(_ tool: CLITool) {
    guard preferredCLITool != tool else { return }
    preferredCLITool = tool
    switchChatCLIProvider(to: tool == .claude ? .claude : .chatGPT)
  }

  func ensurePreferredCLIToolIsValid() {
    // Keep an explicit selection even if that CLI isn't installed yet — the
    // Next button stays disabled until it's detected.
    if preferredCLITool != nil {
      return
    }
    if isToolAvailable(.codex) {
      preferredCLITool = .codex
    } else if isToolAvailable(.claude) {
      preferredCLITool = .claude
    }
  }

  func isToolAvailable(_ tool: CLITool) -> Bool {
    switch tool {
    case .codex:
      if codexCLIStatus.isInstalled { return true }
      return codexCLIReport?.resolvedPath != nil
    case .claude:
      if claudeCLIStatus.isInstalled { return true }
      return claudeCLIReport?.resolvedPath != nil
    }
  }

}

struct SetupStep: Identifiable {
  let id: String
  let title: String
  let contentType: StepContentType
  private(set) var isCompleted: Bool = false

  mutating func markCompleted() {
    isCompleted = true
  }
}

enum StepContentType {
  case apiKeyInput
  case apiKeyInstructions
  case information(String, String)
  case localChoice
  case localModelInstall
  case cliDetection
}

extension ProviderSetupState {
  @MainActor func selectEngine(_ engine: LocalEngine) {
    localEngine = engine
    hasTestedConnection = false
    testSuccessful = false
    if engine != .custom {
      localBaseURL = engine.defaultBaseURL
    }
    let defaultModel = LocalModelPreferences.defaultModelId(
      for: engine == .custom ? .ollama : engine)
    localModelId = defaultModel

  }
}
