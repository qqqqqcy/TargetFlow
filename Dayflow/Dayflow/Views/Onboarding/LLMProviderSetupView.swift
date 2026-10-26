import AppKit
import Foundation
import SwiftUI

struct LLMProviderSetupView: View {
  let providerType: LLMProviderID
  let onBack: () -> Void
  /// Called with the provider that was actually configured — this can differ from
  /// `providerType` when the user switches CLI tools on the detection step.
  let onComplete: (LLMProviderID) -> Bool

  /// The provider currently being configured. Starts as `providerType` but follows
  /// the user's CLI tool selection (ChatGPT ↔ Claude) during setup.
  var effectiveProviderType: LLMProviderID {
    setupState.configuredProviderID ?? providerType
  }

  var headerTitle: String {
    switch effectiveProviderType {
    case .local:
      return String(localized: "Use local AI")
    case .chatGPT:
      return String(localized: "Connect ChatGPT")
    case .claude:
      return String(localized: "Connect Claude")
    case .openAICompatible:
      return String(localized: "Connect an AI endpoint")
    case .gemini:
      return String(localized: "Gemini")
    case .dayflow:
      return String(localized: "Target Flow Pro")
    }
  }

  @StateObject var setupState = ProviderSetupState()
  @State var sidebarOpacity: Double = 0
  @State var contentOpacity: Double = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 18) {
        Button(action: handleBack) {
          Label("Back", systemImage: "chevron.left")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(SettingsStyle.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()

        Text(headerTitle)
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(SettingsStyle.text)
        Spacer()
      }

      HStack(alignment: .top, spacing: 24) {
        SetupSidebarView(
          steps: setupState.steps,
          currentStepId: setupState.currentStep.id,
          onStepSelected: { setupState.navigateToStep($0) }
        )
        .frame(width: 170)
        .opacity(sidebarOpacity)

        ScrollView(.vertical, showsIndicators: true) {
          currentStepContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(SettingsStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
              RoundedRectangle(cornerRadius: 14)
                .strokeBorder(SettingsStyle.divider, lineWidth: 1)
            }
        }
        .opacity(contentOpacity)
        .textSelection(.enabled)
      }
      .frame(maxHeight: .infinity, alignment: .top)

      HStack {
        Spacer()
        nextButton
          .opacity(contentOpacity)
      }
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      setupState.configureSteps(for: providerType)
      animateAppearance()
    }
    .background(SettingsStyle.canvas)
    .tint(SettingsStyle.primaryButtonFill)
    .alert(
      "Couldn't finish setup",
      isPresented: Binding(
        get: { setupState.saveErrorMessage != nil },
        set: { isPresented in
          if !isPresented {
            setupState.saveErrorMessage = nil
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        setupState.saveErrorMessage = nil
      }
    } message: {
      Text(setupState.saveErrorMessage ?? String(localized: "Please try again."))
    }
  }

  var nextButtonText: String {
    if ["verify", "test"].contains(setupState.currentStep.id) && !setupState.testSuccessful {
      return String(localized: "Test Required")
    }
    return String(localized: "Next")
  }

  @ViewBuilder
  var nextButton: some View {
    if setupState.isLastStep {
      DayflowSurfaceButton(
        action: completeSetup,
        content: {
          Text("Complete setup").font(.system(size: 16)).fontWeight(.medium)
        },
        background: SettingsStyle.primaryButtonFill,
        foreground: .white,
        borderColor: SettingsStyle.primaryButtonFill,
        cornerRadius: 9,
        horizontalPadding: 24,
        verticalPadding: 11,
        showOverlayStroke: false,
        innerGlowColor: Color.clear
      )
    } else {
      DayflowSurfaceButton(
        action: handleContinue,
        content: {
          HStack(spacing: 4) {
            Text(nextButtonText).font(.system(size: 16)).fontWeight(.medium)
            if !["verify", "test"].contains(setupState.currentStep.id) || setupState.testSuccessful
            {
              Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 20, height: 20)
            }
          }
          .padding(.leading, 6)
        },
        background: SettingsStyle.primaryButtonFill,
        foreground: .white,
        borderColor: SettingsStyle.primaryButtonFill,
        cornerRadius: 9,
        horizontalPadding: 24,
        verticalPadding: 11,
        showOverlayStroke: false,
        innerGlowColor: Color.clear
      )
      .disabled(!setupState.canContinue)
      .opacity(!setupState.canContinue ? 0.5 : 1.0)
    }
  }

  @ViewBuilder
  var currentStepContent: some View {
    let step = setupState.currentStep

    switch step.contentType {
    case .localChoice:
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Choose your local AI engine")
            .font(.system(size: 24))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text(
            "For local use, LM Studio is the most reliable; Ollama has a known thinking bug in onboarding (can't turn thinking off) and performance is unreliable."
          )
          .font(.system(size: 14))
          .foregroundColor(SettingsStyle.text)
        }
        HStack(alignment: .center, spacing: 12) {
          DayflowSurfaceButton(
            action: {
              setupState.selectEngine(.lmstudio)
              openLMStudioDownload()
            },
            content: {
              AsyncImage(
                url: URL(
                  string:
                    "https://lmstudio.ai/_next/image?url=%2F_next%2Fstatic%2Fmedia%2Flmstudio-app-logo.11b4d746.webp&w=96&q=75"
                )
              ) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure(_):
                  Image(systemName: "desktopcomputer").resizable().scaledToFit().foregroundColor(
                    .white.opacity(0.6))
                case .empty: ProgressView().scaleEffect(0.7)
                @unknown default: EmptyView()
                }
              }
              .frame(width: 18, height: 18)
              Text("Download LM Studio")
                .font(.system(size: 14))
                .fontWeight(.semibold)
            },
            background: SettingsStyle.primaryButtonFill,
            foreground: .white,
            borderColor: SettingsStyle.primaryButtonFill,
            cornerRadius: 9,
            showOverlayStroke: false,
            innerGlowColor: Color.clear
          )
        }
        Text(
          "Already have a local server? Make sure it’s OpenAI-compatible. You can set a custom base URL in the next step."
        )
        .font(.system(size: 13))
        .foregroundColor(SettingsStyle.text)
      }
    case .localModelInstall:
      VStack(alignment: .leading, spacing: 16) {
        Text("Install Qwen3-VL 4B")
          .font(.system(size: 24))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)
        if setupState.localEngine == .ollama {
          Text("After installing Ollama, run this in your terminal to download the model (≈5GB):")
            .font(.system(size: 14))
            .foregroundColor(SettingsStyle.text)
          TerminalCommandView(
            title: String(localized: "Run this command:"),
            subtitle: String(localized: "Downloads Qwen3 Vision 4B for Ollama"),
            command: "ollama pull qwen3-vl:4b"
          )
        } else if setupState.localEngine == .lmstudio {
          VStack(alignment: .leading, spacing: 16) {
            Text("After installing LM Studio, download the recommended model:")
              .font(.system(size: 14))
              .foregroundColor(SettingsStyle.text)

            DayflowSurfaceButton(
              action: openLMStudioModelDownload,
              content: {
                HStack(spacing: 8) {
                  Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                  Text("Download Qwen3-VL 4B in LM Studio").font(.system(size: 14))
                    .fontWeight(.semibold)
                }
              },
              background: SettingsStyle.primaryButtonFill,
              foreground: .white,
              borderColor: SettingsStyle.primaryButtonFill,
              cornerRadius: 9,
              horizontalPadding: 24,
              verticalPadding: 12,
              showOverlayStroke: false,
              innerGlowColor: Color.clear
            )

            VStack(alignment: .leading, spacing: 6) {
              Text("This will open LM Studio and prompt you to download the model (≈3GB).")
                .font(.system(size: 13))
                .foregroundColor(SettingsStyle.text)

              Text(
                "Once downloaded, turn on 'Local Server' in LM Studio (default http://localhost:1234)"
              )
              .font(.system(size: 13))
              .foregroundColor(SettingsStyle.text)
            }
            .padding(.top, 4)

            // Fallback manual instructions
            VStack(alignment: .leading, spacing: 4) {
              Text("Manual setup:")
                .font(.system(size: 12))
                .fontWeight(.semibold)
                .foregroundColor(SettingsStyle.secondary)
              Text("1. Open LM Studio → Models tab")
                .font(.system(size: 12))
                .foregroundColor(SettingsStyle.secondary)
              Text("2. Search for 'Qwen3-VL-4B' and install the Instruct variant")
                .font(.system(size: 12))
                .foregroundColor(SettingsStyle.secondary)
            }
            .padding(.top, 8)
          }
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text("Use any OpenAI-compatible VLM")
              .font(.system(size: 16))
              .fontWeight(.semibold)
              .foregroundColor(SettingsStyle.text)
            Text(
              "Make sure your server exposes the OpenAI Chat Completions API and has Qwen3-VL 4B (or Qwen2.5-VL 3B if you need the legacy model) installed."
            )
            .font(.system(size: 14))
            .foregroundColor(SettingsStyle.text)
          }
        }
      }
    case .terminalCommand(let command):
      VStack(alignment: .leading, spacing: 24) {
        TerminalCommandView(
          title: String(localized: "Terminal command:"),
          subtitle: String(localized: "Copy the code below and try running it in your terminal"),
          command: command
        )

      }

    case .apiKeyInput:
      VStack(alignment: .leading, spacing: 24) {
        APIKeyInputView(
          apiKey: $setupState.apiKey,
          title: String(localized: "Enter your API key:"),
          subtitle: String(localized: "Paste your Gemini API key below"),
          placeholder: "AQ...",
          onValidate: { key in
            key.components(separatedBy: .whitespacesAndNewlines).joined().count > 10
          }
        )
        .onChange(of: setupState.apiKey) { _, _ in
          setupState.clearGeminiAPIKeySaveError()
          setupState.hasTestedConnection = false
          setupState.testSuccessful = false
        }

        if let message = setupState.geminiAPIKeySaveError {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 12))
              .foregroundColor(SettingsStyle.destructive)

            Text(message)
              .font(.system(size: 13))
              .foregroundColor(SettingsStyle.destructive)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(SettingsStyle.destructive.opacity(0.1))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(SettingsStyle.destructive.opacity(0.3), lineWidth: 1)
          )
        }

        VStack(alignment: .leading, spacing: 12) {
          Text(
            "Choose your Gemini model. We recommend 3.5 Flash, with 3.1 Flash-Lite available as a fallback."
          )
          .font(.system(size: 16))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)

          Picker("Gemini model", selection: $setupState.geminiModel) {
            ForEach(GeminiModel.allCases, id: \.self) { model in
              Text(model.shortLabel).tag(model)
            }
          }
          .pickerStyle(.segmented)

          Text(GeminiModelPreference(primary: setupState.geminiModel).fallbackSummary)
            .font(.system(size: 13))
            .foregroundColor(SettingsStyle.secondary)
        }
        .onChange(of: setupState.geminiModel) {
          setupState.persistGeminiModelSelection(source: "onboarding_picker")
        }

      }

    case .modelDownload(let command):
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Download the AI model")
            .font(.system(size: 24))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)

          Text("This model enables Target Flow to understand what's on your screen")
            .font(.system(size: 14))
            .foregroundColor(SettingsStyle.text)
        }

        TerminalCommandView(
          title: String(localized: "Run this command:"),
          subtitle:
            String(
              localized:
                "This will download the \(LocalModelPreset.qwen3VL4B.displayName) model (about 5GB)"
            ),
          command: command
        )

      }

    case .information(let title, let description):
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(title)
              .font(.system(size: 24))
              .fontWeight(.semibold)
              .foregroundColor(SettingsStyle.text)
          }
          if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(description)
              .font(.system(size: 16))
              .foregroundColor(SettingsStyle.text)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
              .lineLimit(nil)
              .frame(maxWidth: 500, alignment: .leading)
            // Additional guidance for the local intro step only
            if step.id == "intro" && providerType == .local {
              Text(
                "Advanced users can pick any **vision-capable** LLM, but we strongly recommend using Qwen3-VL 4B based on our internal benchmarks."
              )
              .font(.system(size: 16))
              .foregroundColor(SettingsStyle.text)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: 500, alignment: .leading)
            }
          }
        }

        Group {
          VStack(alignment: .leading, spacing: 16) {
            if ["verify", "test"].contains(step.id) {
              if providerType == .gemini {
                TestConnectionView(
                  apiKey: setupState.apiKey,
                  model: setupState.geminiModel,
                  onTestComplete: { success in
                    setupState.hasTestedConnection = true
                    setupState.testSuccessful = success
                  }
                )
              } else if providerType == .chatGPT || providerType == .claude {
                ChatCLITestView(
                  selectedTool: setupState.preferredCLITool,
                  onTestComplete: { success in
                    setupState.hasTestedConnection = true
                    setupState.testSuccessful = success
                  },
                  usesOnboardingStyle: true
                )
              } else if providerType == .openAICompatible {
                VStack(alignment: .leading, spacing: 12) {
                  Picker("Endpoint", selection: $setupState.openAICompatiblePreset) {
                    Text("OpenRouter").tag(OpenAICompatiblePreset.openRouter)
                    Text("Custom").tag(OpenAICompatiblePreset.custom)
                  }
                  .pickerStyle(.segmented)
                  .frame(maxWidth: 380)
                  .onChange(of: setupState.openAICompatiblePreset) { _, preset in
                    if preset == .openRouter {
                      setupState.openAICompatibleBaseURL =
                        OpenAICompatibleConfiguration.openRouterBaseURL
                    }
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }

                  LocalLLMTestView(
                    baseURL: $setupState.openAICompatibleBaseURL,
                    modelId: $setupState.openAICompatibleModelID,
                    apiKey: $setupState.openAICompatibleAPIKey,
                    engine: .custom,
                    buttonLabel: String(localized: "Test endpoint"),
                    basePlaceholder: OpenAICompatibleConfiguration.openRouterBaseURL,
                    modelPlaceholder: "openai/gpt-5.6-sol",
                    credentialStorageDescription:
                      String(
                        localized:
                          "Stored safely in Keychain and sent only to this endpoint as a Bearer token."
                      ),
                    requiresMeaningfulResponse: true,
                    enforcesLocalLatencyLimit: false,
                    onTestComplete: { success in
                      setupState.hasTestedConnection = true
                      setupState.testSuccessful = success
                    }
                  )
                  .onChange(of: setupState.openAICompatibleBaseURL) {
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }
                  .onChange(of: setupState.openAICompatibleModelID) {
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }
                  .onChange(of: setupState.openAICompatibleAPIKey) {
                    setupState.hasTestedConnection = false
                    setupState.testSuccessful = false
                  }
                }
              } else {
                // Engine selection: LM Studio or Custom
                VStack(alignment: .leading, spacing: 12) {
                  Text("Which tool are you using?")
                    .font(.system(size: 14))
                    .foregroundColor(SettingsStyle.text)
                  Picker("Engine", selection: $setupState.localEngine) {
                    Text("LM Studio").tag(LocalEngine.lmstudio)
                    Text("Custom model").tag(LocalEngine.custom)
                  }
                  .pickerStyle(.segmented)
                  .frame(maxWidth: 380)
                }
                .onChange(of: setupState.localEngine) { _, newValue in
                  setupState.selectEngine(newValue)
                }

                LocalLLMTestView(
                  baseURL: $setupState.localBaseURL,
                  modelId: $setupState.localModelId,
                  apiKey: $setupState.localAPIKey,
                  engine: setupState.localEngine,
                  showInputs: setupState.localEngine == .custom,
                  onTestComplete: { success in
                    setupState.hasTestedConnection = true
                    setupState.testSuccessful = success
                  }
                )
                .onChange(of: setupState.localBaseURL) {
                  setupState.hasTestedConnection = false
                  setupState.testSuccessful = false
                }
                .onChange(of: setupState.localModelId) {
                  setupState.hasTestedConnection = false
                  setupState.testSuccessful = false
                }
                .onChange(of: setupState.localAPIKey) {
                  setupState.hasTestedConnection = false
                  setupState.testSuccessful = false
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
        }

      }

    case .cliDetection:
      ChatCLIDetectionStepView(
        codexStatus: setupState.codexCLIStatus,
        codexReport: setupState.codexCLIReport,
        claudeStatus: setupState.claudeCLIStatus,
        claudeReport: setupState.claudeCLIReport,
        isChecking: setupState.isCheckingCLIStatus,
        onRetry: { setupState.refreshCLIStatuses() },
        onInstall: { tool in openChatCLIInstallPage(for: tool) },
        selectedTool: setupState.preferredCLITool,
        onSelectTool: { tool in setupState.selectPreferredCLITool(tool) }
      )
      .onAppear {
        setupState.ensureCLICheckStarted()
      }

    case .apiKeyInstructions:
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Get your Gemini API key")
            .font(.system(size: 24))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)

          Text(
            "allows you to run Target Flow for free. All you need is a Google account - no credit card required."
          )
          .font(.system(size: 14))
          .foregroundColor(SettingsStyle.text)
        }

        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 12) {
            Text("1.")
              .font(.system(size: 14))
              .foregroundColor(SettingsStyle.text)
              .frame(width: 20, alignment: .leading)

            Button(action: openGoogleAIStudio) {
              Text("Visit Google AI Studio ")
                .font(.system(size: 14))
                .foregroundColor(SettingsStyle.text)
                + Text("(aistudio.google.com)")
                .font(.system(size: 14))
                .foregroundColor(SettingsStyle.ink)
                .underline()
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
          }

          HStack(alignment: .top, spacing: 12) {
            Text("2.")
              .font(.system(size: 14))
              .foregroundColor(SettingsStyle.text)
              .frame(width: 20, alignment: .leading)

            Text("Click \"Create API key\" in the top right")
              .font(.system(size: 14))
              .foregroundColor(SettingsStyle.text)
          }

          HStack(alignment: .top, spacing: 12) {
            Text("3.")
              .font(.system(size: 14))
              .foregroundColor(SettingsStyle.text)
              .frame(width: 20, alignment: .leading)

            Text("Create a new API key and copy it")
              .font(.system(size: 14))
              .foregroundColor(SettingsStyle.text)
          }
        }
        .padding(.vertical, 12)

        HStack {
          DayflowSurfaceButton(
            action: openGoogleAIStudio,
            content: {
              HStack(spacing: 8) {
                Image(systemName: "safari").font(.system(size: 14))
                Text("Open Google AI Studio").font(.system(size: 14)).fontWeight(
                  .semibold)
              }
            },
            background: SettingsStyle.primaryButtonFill,
            foreground: .white,
            borderColor: SettingsStyle.primaryButtonFill,
            cornerRadius: 9,
            horizontalPadding: 24,
            verticalPadding: 12,
            showOverlayStroke: false,
            innerGlowColor: Color.clear
          )
          Spacer()
        }
      }
    }
  }

  func handleBack() {
    if setupState.currentStepIndex == 0 {
      onBack()
    } else {
      setupState.goBack()
    }
  }

  func handleContinue() {
    if setupState.isLastStep {
      completeSetup()
    } else {
      setupState.markCurrentStepCompleted()
      setupState.goNext()
    }
  }

  @discardableResult
  func saveConfiguration() -> Bool {
    setupState.saveErrorMessage = nil
    guard setupState.testSuccessful else {
      setupState.saveErrorMessage = String(
        localized: "Test this provider successfully before completing setup.")
      return false
    }

    // Save API key to keychain for Gemini
    if providerType == .gemini {
      let cleanedKey = setupState.apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
      if !cleanedKey.isEmpty {
        guard KeychainManager.shared.store(cleanedKey, for: "gemini") else {
          let message =
            String(
              localized:
                "Couldn't save your API key to Keychain. Please unlock Keychain and try again.")
          setupState.geminiAPIKeySaveError = message
          setupState.saveErrorMessage = message
          return false
        }
      }
      GeminiModelPreference(primary: setupState.geminiModel).save()
    }

    // Save local endpoint for local engine selection
    if providerType == .local {
      persistLocalSettings()
    }

    if providerType == .openAICompatible {
      guard persistOpenAICompatibleSettings() else {
        setupState.saveErrorMessage =
          String(
            localized:
              "Target Flow couldn't save this endpoint configuration. Your previous configuration is still active."
          )
        return false
      }
    }

    do {
      try LLMProviderSetupPreferences.markComplete(effectiveProviderType)
      return true
    } catch {
      setupState.saveErrorMessage =
        String(localized: "Target Flow couldn't finish saving this provider. Please try again.")
      return false
    }
  }

  func completeSetup() {
    guard saveConfiguration() else { return }
    guard onComplete(effectiveProviderType) else {
      setupState.saveErrorMessage =
        String(
          localized:
            "The provider is configured, but Target Flow couldn't update your routing. Your previous selection is still active."
        )
      return
    }
  }

  func persistLocalSettings() {
    let endpoint = setupState.localBaseURL
    UserDefaults.standard.set(setupState.localModelId, forKey: "llmLocalModelId")
    LocalModelPreferences.syncPreset(for: setupState.localEngine, modelId: setupState.localModelId)
    // Store local engine selection for header/model defaults
    UserDefaults.standard.set(setupState.localEngine.rawValue, forKey: "llmLocalEngine")
    // Also store the endpoint explicitly for other parts of the app if needed
    UserDefaults.standard.set(endpoint, forKey: "llmLocalBaseURL")
    persistLocalAPIKey(setupState.localAPIKey)
  }

  func persistOpenAICompatibleSettings() -> Bool {
    let configuration = OpenAICompatibleConfiguration(
      preset: setupState.openAICompatiblePreset,
      baseURL: setupState.openAICompatibleBaseURL,
      modelID: setupState.openAICompatibleModelID
    )
    guard configuration.isComplete else { return false }

    let key = setupState.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let previousKey = KeychainManager.shared.retrieve(
      for: OpenAICompatiblePreferences.keychainProvider)
    if key.isEmpty {
      guard KeychainManager.shared.delete(for: OpenAICompatiblePreferences.keychainProvider) else {
        return false
      }
    } else if !KeychainManager.shared.store(
      key,
      for: OpenAICompatiblePreferences.keychainProvider
    ) {
      return false
    }

    guard OpenAICompatiblePreferences.save(configuration) else {
      if let previousKey {
        _ = KeychainManager.shared.store(
          previousKey,
          for: OpenAICompatiblePreferences.keychainProvider
        )
      } else {
        _ = KeychainManager.shared.delete(for: OpenAICompatiblePreferences.keychainProvider)
      }
      return false
    }
    return true
  }

  func persistLocalAPIKey(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      UserDefaults.standard.removeObject(forKey: "llmLocalAPIKey")
    } else {
      UserDefaults.standard.set(trimmed, forKey: "llmLocalAPIKey")
    }
  }

  func openGoogleAIStudio() {
    if let url = URL(string: "https://aistudio.google.com/app/apikey") {
      NSWorkspace.shared.open(url)
    }
  }

  func openLMStudioDownload() {
    if let url = URL(string: "https://lmstudio.ai/") {
      NSWorkspace.shared.open(url)
    }
  }

  func openLMStudioModelDownload() {
    if let url = URL(
      string: "https://model.lmstudio.ai/download/lmstudio-community/Qwen3-VL-4B-Instruct-GGUF")
    {
      NSWorkspace.shared.open(url)
    }
  }

  func openChatCLIInstallPage(for tool: CLITool) {
    guard let url = tool.installURL else { return }
    NSWorkspace.shared.open(url)
  }

  func animateAppearance() {
    withAnimation(.easeOut(duration: 0.4)) {
      sidebarOpacity = 1
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      withAnimation(.easeOut(duration: 0.4)) {
        contentOpacity = 1
      }
    }
  }
}
