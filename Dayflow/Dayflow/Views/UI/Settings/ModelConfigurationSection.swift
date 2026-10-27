import SwiftUI

struct ModelConfigurationSection: View {
  private enum FallbackMode: String, CaseIterable {
    case legacy, disabled, custom

    var title: String {
      switch self {
      case .legacy: return String(localized: "Use existing fallback behavior")
      case .disabled: return String(localized: "Disable model fallback")
      case .custom: return String(localized: "Custom fallback models")
      }
    }
  }

  @State private var provider: LLMProviderID
  @State private var preferences = ModelPreferences()
  @State private var feature: ModelFeature = .timeline
  @State private var fallbackMode: FallbackMode = .legacy
  @State private var fallbackText = ""
  @State private var status: String?
  @State private var isError = false

  init(initialProvider: LLMProviderID) {
    _provider = State(initialValue: initialProvider == .dayflow ? .gemini : initialProvider)
  }

  var body: some View {
    SettingsSection(
      title: String(localized: "Model configuration"),
      subtitle: String(localized: "Set provider defaults and override models for individual features.")
    ) {
      VStack(alignment: .leading, spacing: 18) {
        Picker("Provider", selection: $provider) {
          ForEach(LLMProviderID.allCases.filter { $0 != .dayflow }, id: \.self) { value in
            Text(providerName(value)).tag(value)
          }
        }
        .pickerStyle(.menu)

        VStack(alignment: .leading, spacing: 10) {
          heading(String(localized: "Global default"))
          selectionEditor(selection: $preferences.defaultSelection)
          help(String(localized: "An empty model and inherited reasoning keep each feature’s existing app defaults."))
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
          heading(String(localized: "Feature override"))
          Picker("Feature", selection: $feature) {
            ForEach(supportedFeatures) { value in
              Text(value.displayName).tag(value)
            }
          }
          .pickerStyle(.menu)

          Toggle("Customize this feature", isOn: featureEnabled)
            .toggleStyle(SwitchToggleStyle(tint: SettingsStyle.ink))
          if preferences.featureOverrides[feature] != nil {
            selectionEditor(selection: featureSelection)
          }
          help(effectiveSummary)
        }

        Divider()

        if provider != .claude {
        VStack(alignment: .leading, spacing: 10) {
          heading(String(localized: "Model fallback"))
          Picker("Fallback", selection: $fallbackMode) {
            ForEach(FallbackMode.allCases, id: \.self) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.menu)
          if fallbackMode == .custom {
            TextEditor(text: $fallbackText)
              .font(.system(size: 12, design: .monospaced))
              .scrollContentBackground(.hidden)
              .padding(8)
              .frame(height: 90)
              .background(SettingsStyle.editorFill)
              .overlay(RoundedRectangle(cornerRadius: 7).stroke(SettingsStyle.editorBorder))
            help(String(localized: "Enter one model per line, in retry order. Model fallback stays within this provider; provider failover is configured separately."))
          }
        }

        }

        if let status {
          Text(status)
            .font(.system(size: 12))
            .foregroundColor(isError ? SettingsStyle.destructive : SettingsStyle.statusGood)
        }
        HStack {
          help(String(localized: "Edits apply after saving. Switching providers discards unsaved edits."))
          Spacer()
          SettingsSecondaryButton(title: String(localized: "Save model configuration"), action: save)
        }
      }
    }
    .onAppear(perform: load)
    .onChange(of: provider) { _, _ in load() }
    .onChange(of: preferences) { _, _ in status = nil }
    .onChange(of: fallbackMode) { _, _ in status = nil }
    .onChange(of: fallbackText) { _, _ in status = nil }
  }

  private var featureEnabled: Binding<Bool> {
    Binding(
      get: { preferences.featureOverrides[feature] != nil },
      set: { enabled in
        preferences.featureOverrides[feature] = enabled ? ModelOverride() : nil
      }
    )
  }

  private var featureSelection: Binding<ModelOverride> {
    Binding(
      get: { preferences.featureOverrides[feature] ?? ModelOverride() },
      set: { preferences.featureOverrides[feature] = $0 }
    )
  }

  private func selectionEditor(selection: Binding<ModelOverride>) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Model (empty to inherit)", text: selection.model)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(String(localized: "Model"))
      let recommendations = ModelPreferences.recommendedModels(for: provider)
      if !recommendations.isEmpty {
        Menu("Recommended models") {
          ForEach(recommendations, id: \.self) { model in
            Button(model) { selection.wrappedValue.model = model }
          }
        }
        .fixedSize()
      }
      Picker("Reasoning", selection: selection.reasoningEffort) {
        Text("Inherit").tag(Optional<ModelReasoningEffort>.none)
        ForEach(ModelReasoningEffort.choices(
          for: provider,
          model: selection.wrappedValue.model.isEmpty
            ? preferences.defaultSelection.model : selection.wrappedValue.model)) { effort in
          Text(effort.displayName).tag(Optional(effort))
        }
      }
      .pickerStyle(.menu)
      help(String(localized: "Available reasoning levels depend on the provider and model. Custom model names are accepted."))
    }
  }

  private var supportedFeatures: [ModelFeature] {
    switch provider {
    case .chatGPT, .claude: return ModelFeature.allCases
    case .gemini: return [.transcription, .activityCards, .chat, .text, .dailyRecap]
    case .local, .openAICompatible: return [.transcription, .activityCards, .text, .dailyRecap]
    case .dayflow: return []
    }
  }

  private var legacySelection: ModelSelection {
    switch provider {
    case .chatGPT:
      switch feature {
      case .timeline: return ModelSelection(model: "gpt-6-luna", reasoningEffort: "high")
      case .transcription: return ModelSelection(model: "gpt-6-luna", reasoningEffort: "low")
      case .activityCards, .dailyRecap: return ModelSelection(model: "gpt-6.1-sol", reasoningEffort: "low")
      case .chat: return ModelSelection(model: "gpt-5.6-luna", reasoningEffort: "low")
      case .text: return ModelSelection(model: "gpt-5.2", reasoningEffort: "high")
      case .flow:
        let settings = FlowAgentSettings.shared
        return ModelSelection(model: settings.model, reasoningEffort: settings.reasoningEffort)
      }
    case .claude:
      switch feature {
      case .timeline: return ModelSelection(model: "haiku", reasoningEffort: "medium")
      case .transcription, .activityCards: return ModelSelection(model: "sonnet", reasoningEffort: "low")
      case .chat: return ModelSelection(model: "sonnet", reasoningEffort: nil)
      case .text: return ModelSelection(model: "sonnet", reasoningEffort: "high")
      case .dailyRecap: return ModelSelection(model: "opus", reasoningEffort: nil)
      case .flow: return ModelSelection(model: "haiku", reasoningEffort: nil)
      }
    case .gemini:
      let model = feature == .chat
        ? GeminiDirectProvider.dashboardChatModels[0].rawValue
        : GeminiModelPreference.load().primary.rawValue
      return ModelSelection(model: model, reasoningEffort: "high")
    case .openAICompatible:
      let configuration = OpenAICompatiblePreferences.load()
      let isOpenRouter = configuration.flatMap { URL(string: $0.baseURL) }?.host?.lowercased() == "openrouter.ai"
      return ModelSelection(
        model: configuration?.modelID ?? "",
        reasoningEffort: isOpenRouter && feature != .text && feature != .dailyRecap ? "low" : nil)
    case .local:
      let engine = LocalEngine(rawValue: UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama") ?? .ollama
      let model = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? ""
      return ModelSelection(model: model.isEmpty ? LocalModelPreferences.defaultModelId(for: engine) : model, reasoningEffort: nil)
    case .dayflow: return ModelSelection(model: "", reasoningEffort: nil)
    }
  }

  private var effectiveSummary: String {
    let legacy = legacySelection
    let effective = preferences.resolve(
      provider: provider, feature: feature, defaultModel: legacy.model, defaultEffort: legacy.reasoningEffort)
    let model = effective.model.isEmpty ? String(localized: "Not configured") : effective.model
    let effort = effective.reasoningEffort ?? String(localized: "Provider default (omit effort)")
    return "\(String(localized: "Effective model")): \(model) · \(String(localized: "Reasoning")): \(effort)"
  }

  private func load() {
    preferences = ModelPreferences.load(provider: provider)
    if !supportedFeatures.contains(feature), let first = supportedFeatures.first { feature = first }
    switch preferences.fallbackModels {
    case nil: fallbackMode = .legacy
    case .some(let models): fallbackMode = models.isEmpty ? .disabled : .custom
    }
    fallbackText = (preferences.fallbackModels ?? []).joined(separator: "\n")
    status = nil
  }

  private func save() {
    var candidate = preferences
    switch fallbackMode {
    case .legacy: candidate.fallbackModels = nil
    case .disabled: candidate.fallbackModels = []
    case .custom:
      let models = fallbackText.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      guard !models.isEmpty else {
        isError = true
        status = String(localized: "Enter at least one fallback model, or choose Disable model fallback.")
        return
      }
      candidate.fallbackModels = models
    }
    do {
      try candidate.save(provider: provider)
      isError = false
      status = String(localized: "Model configuration saved.")
    } catch {
      isError = true
      status = error.localizedDescription
    }
  }

  private func heading(_ text: String) -> some View {
    Text(text).font(.system(size: 14, weight: .semibold)).foregroundColor(SettingsStyle.text)
  }

  private func help(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func providerName(_ provider: LLMProviderID) -> String {
    switch provider {
    case .chatGPT: return "ChatGPT (Codex)"
    case .claude: return "Claude"
    case .gemini: return "Gemini"
    case .openAICompatible: return String(localized: "OpenAI compatible")
    case .local: return String(localized: "Local")
    case .dayflow: return "Hosted"
    }
  }
}
