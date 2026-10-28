import Foundation
import SwiftUI

@MainActor
final class ProvidersSettingsViewModel: ObservableObject {
  let defaults: UserDefaults

  init(defaults: UserDefaults = AppStoragePaths.defaults) {
    self.defaults = defaults
  }

  @Published var setupModalProvider: LLMProviderID?
  @Published var providerRoutingErrorMessage: String?

  @Published var sharedPromptOverridesLoaded = false
  var isUpdatingSharedPromptState = false
  @Published var useCustomTitlePrompt = false {
    didSet { persistSharedPromptOverridesIfReady() }
  }
  @Published var useCustomSummaryPrompt = false {
    didSet { persistSharedPromptOverridesIfReady() }
  }
  @Published var useCustomDetailedPrompt = false {
    didSet { persistSharedPromptOverridesIfReady() }
  }
  @Published var titlePromptText = CodexPromptDefaults.titleBlock {
    didSet { persistSharedPromptOverridesIfReady() }
  }
  @Published var summaryPromptText = CodexPromptDefaults.summaryBlock {
    didSet { persistSharedPromptOverridesIfReady() }
  }
  @Published var detailedPromptText = CodexPromptDefaults.detailedSummaryBlock {
    didSet { persistSharedPromptOverridesIfReady() }
  }

  func handleOnAppear() {
    loadSharedPromptOverridesIfNeeded()
  }

  func editProviderConfiguration(_ providerID: LLMProviderID) {
    guard providerID == .chatGPT || providerID == .claude else { return }
    setupModalProvider = providerID
  }

  func handleProviderSetupCompletion(_ providerID: LLMProviderID) -> Bool {
    setupModalProvider != nil
      && (providerID == .chatGPT || providerID == .claude)
  }

  func cancelProviderSetup() {
    setupModalProvider = nil
  }
}
