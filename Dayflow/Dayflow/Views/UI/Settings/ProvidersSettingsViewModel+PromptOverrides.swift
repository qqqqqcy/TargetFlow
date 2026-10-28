import Foundation

extension ProvidersSettingsViewModel {
  func loadSharedPromptOverridesIfNeeded(force: Bool = false) {
    if sharedPromptOverridesLoaded && !force { return }
    isUpdatingSharedPromptState = true
    let overrides = ActivityCardPromptPreferences.load(from: defaults)
    useCustomTitlePrompt = normalizedOverride(text: overrides.titleBlock ?? "", enabled: true) != nil
    useCustomSummaryPrompt = normalizedOverride(text: overrides.summaryBlock ?? "", enabled: true) != nil
    useCustomDetailedPrompt = normalizedOverride(text: overrides.detailedBlock ?? "", enabled: true) != nil
    titlePromptText = overrides.titleBlock ?? CodexPromptDefaults.titleBlock
    summaryPromptText = overrides.summaryBlock ?? CodexPromptDefaults.summaryBlock
    detailedPromptText = overrides.detailedBlock ?? CodexPromptDefaults.detailedSummaryBlock
    isUpdatingSharedPromptState = false
    sharedPromptOverridesLoaded = true
  }

  func persistSharedPromptOverridesIfReady() {
    guard sharedPromptOverridesLoaded, !isUpdatingSharedPromptState else { return }
    let overrides = ActivityCardPromptOverrides(
      titleBlock: normalizedOverride(text: titlePromptText, enabled: useCustomTitlePrompt),
      summaryBlock: normalizedOverride(text: summaryPromptText, enabled: useCustomSummaryPrompt),
      detailedBlock: normalizedOverride(text: detailedPromptText, enabled: useCustomDetailedPrompt)
    )
    do {
      try ActivityCardPromptPreferences.saveVerified(overrides, to: defaults)
    } catch {
      providerRoutingErrorMessage = String(localized: "The activity-card prompts could not be saved.")
    }
  }

  func resetSharedPromptOverrides() {
    do {
      try ActivityCardPromptPreferences.saveVerified(ActivityCardPromptOverrides(), to: defaults)
      loadSharedPromptOverridesIfNeeded(force: true)
    } catch {
      providerRoutingErrorMessage = String(localized: "The activity-card prompts could not be saved.")
    }
  }

  func normalizedOverride(text: String, enabled: Bool) -> String? {
    guard enabled else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
