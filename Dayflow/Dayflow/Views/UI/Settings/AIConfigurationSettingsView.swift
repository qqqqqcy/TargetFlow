import SwiftUI

/// Connections are saved independently of the feature routes that use them.
struct AIConfigurationSettingsView: View {
  @ObservedObject var viewModel: ProvidersSettingsViewModel
  @State private var configuration = AIConfiguration()
  @State private var tab = 0
  @State private var editingConnection: AIProviderConnection?
  @State private var deletingConnection: AIProviderConnection?
  @State private var status: String?
  @State private var isError = false
  @State private var savedConfiguration: AIConfiguration?
  @State private var loaded = false
  @State private var example: AIConfigurationExample?
  private var hasChanges: Bool { savedConfiguration.map { $0 != configuration } ?? false }
  @StateObject private var validator = AIConfigurationValidator()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsSection(
        title: String(localized: "AI configuration"),
        subtitle: String(localized: "Add provider connections, then choose a default model and optional feature models.")
      ) {
        VStack(alignment: .leading, spacing: 16) {
          Picker(String(localized: "Configuration steps"), selection: $tab) {
            Text("1. Providers").tag(0)
            Text("2. Feature models").tag(1)
          }
          .pickerStyle(.segmented)
          .controlSize(.large)
          .labelsHidden()
          .padding(4)
          .background(SettingsStyle.editorFill, in: RoundedRectangle(cornerRadius: 10))
          .accessibilityLabel(String(localized: "Configuration steps"))
          if tab == 0 { connectionsPanel } else { routesPanel }
          Divider()
          HStack(spacing: 12) {
            if let status {
              Text(status)
                .font(.system(size: 12))
                .foregroundColor(isError ? SettingsStyle.destructive : SettingsStyle.statusGood)
                .fixedSize(horizontal: false, vertical: true)
            } else if hasChanges {
              Text("Unsaved changes")
                .font(.system(size: 12))
                .foregroundColor(SettingsStyle.statusWarn)
            }
            Spacer()
            Button(String(localized: "Save configuration"), action: save)
              .buttonStyle(.borderedProminent)
              .disabled(!loaded || !hasChanges)
          }
        }
      }
      validationPanel
    }
    .sheet(item: $example) { example in
      AIConfigurationExampleSheet(example: example)
    }
    .onAppear(perform: load)
    .onChange(of: configuration) { _, _ in
      guard loaded else { return }
      status = nil
      validator.invalidate()
    }
    .confirmationDialog(
      String(localized: "Delete provider connection?"),
      isPresented: Binding(get: { deletingConnection != nil }, set: { if !$0 { deletingConnection = nil } }),
      presenting: deletingConnection
    ) { connection in
      Button(String(localized: "Delete connection and assignments"), role: .destructive) {
        removeConnection(connection)
        deletingConnection = nil
      }
      Button(String(localized: "Cancel"), role: .cancel) { deletingConnection = nil }
    } message: { connection in
      Text(deletionSummary(connection))
    }
    .sheet(item: $editingConnection) { connection in
      AIConnectionEditor(
        connection: connection,
        onCLISetup: { kind in
          editingConnection = nil
          viewModel.editProviderConfiguration(kind == .claudeCLI ? .claude : .chatGPT)
        },
        onSave: { connection, secret in
          var candidate = configuration
          if let index = candidate.connections.firstIndex(where: { $0.id == connection.id }) {
            candidate.connections[index] = connection
          } else {
            candidate.connections.append(connection)
          }
          if let secret { try AIConfigurationStore.shared.saveSecret(secret, for: connection) }
          try AIConfigurationStore.shared.save(candidate)
          configuration = candidate
          savedConfiguration = candidate
          isError = false
          Task { @MainActor in status = String(localized: "Configuration saved") }
          validator.invalidate()
          editingConnection = nil
        })
    }
  }

  private var connectionsPanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Saved connections")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Menu {
          Section(String(localized: "Subscription / sign-in")) {
            presetButtons([.codex, .claude])
          }
          Section(String(localized: "API / proxy")) {
            presetButtons([.openRouter, .openAI, .deepSeek, .kimi, .gemini, .custom])
          }
          Section(String(localized: "Local")) {
            presetButtons([.ollama, .lmStudio])
          }
        } label: {
          Label(String(localized: "Add provider"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!loaded)
      }
      .padding(.bottom, 12)
      if configuration.connections.isEmpty {
        emptyState(
          String(localized: "No provider connections yet"),
          detail: String(localized: "Add an API, subscription CLI, or local service. You can add multiple connections for the same provider."))
      } else {
        ForEach(configuration.connections) { connection in
          connectionRow(connection)
          if connection.id != configuration.connections.last?.id { Divider() }
        }
      }
      Text("API keys are stored in local files readable only by your macOS user. Subscription CLIs use your existing local sign-in.")
        .font(.system(size: 11))
        .foregroundColor(SettingsStyle.secondary)
        .padding(.top, 12)
    }
  }

  private func presetButtons(_ presets: [AIConnectionPreset]) -> some View {
    ForEach(presets) { preset in
      Button(preset.title) { editingConnection = preset.connection }
        .accessibilityLabel(String(localized: "Add \(preset.title) connection"))
    }
  }

  private func connectionRow(_ connection: AIProviderConnection) -> some View {
    HStack(spacing: 12) {
      Image(systemName: connection.kind == .local ? "desktopcomputer" : "network")
        .foregroundColor(SettingsStyle.ink)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(connection.name).font(.system(size: 13, weight: .semibold))
        Text("\(connection.kind.displayName) · \(connection.models.count) models")
          .font(.system(size: 11))
          .foregroundColor(SettingsStyle.secondary)
        if let endpoint = connection.endpoint, !endpoint.isEmpty {
          Text(endpoint).font(.system(size: 11)).foregroundColor(SettingsStyle.meta)
            .lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer(minLength: 4)
      Toggle(String(localized: "Enabled"), isOn: Binding(
        get: { configuration.connections.first(where: { $0.id == connection.id })?.enabled ?? false },
        set: { value in
          if let index = configuration.connections.firstIndex(where: { $0.id == connection.id }) {
            configuration.connections[index].enabled = value
          }
        }))
        .labelsHidden().toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel(String(localized: "Enable \(connection.name)"))
      Button(String(localized: "Edit")) { editingConnection = connection }
        .accessibilityLabel(String(localized: "Edit \(connection.name)"))
        .buttonStyle(.borderless)
      Menu {
        Button(String(localized: "Duplicate connection")) {
          var copy = connection
          copy = AIProviderConnection(
            name: connection.name + String(localized: " copy"), kind: connection.kind,
            endpoint: connection.endpoint, enabled: connection.enabled, models: connection.models,
            localEngine: connection.localEngine)
          editingConnection = copy
        }
        Button(String(localized: "Delete connection"), role: .destructive) {
          deletingConnection = connection
        }
      } label: { Image(systemName: "ellipsis") }
      .menuStyle(.borderlessButton).fixedSize()
      .accessibilityLabel(String(localized: "More connection actions"))
    }
    .padding(.vertical, 12)
  }

  private var routesPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Choose a default for all features, then customize individual features if needed.")
        .font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
      featureEditor(nil)
      ForEach(AIFeature.configurableCases) { feature in
        featureEditor(feature)
      }
    }
  }

  private func featureEditor(_ feature: AIFeature?) -> some View {
    let assignment = feature.flatMap { configuration.routes[$0]?.primary } ?? (feature == nil ? configuration.defaultModel : nil)
    let title = feature?.displayName ?? String(localized: "Default model")
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Label(title, systemImage: feature.map(featureIcon) ?? "slider.horizontal.3")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        if let feature {
          Button {
            example = AIConfigurationExample(feature: feature)
          } label: {
            Label(String(localized: "Examples"), systemImage: "doc.text.magnifyingglass")
          }
          .buttonStyle(.borderless)
          .font(.system(size: 11))
          .accessibilityLabel(String(localized: "View examples for \(title)"))
        }
      }
      if let feature {
        Label([AIFeature.timeline, .transcription].contains(feature)
          ? String(localized: "Image input required") : String(localized: "Text input only · No images required"),
          systemImage: [AIFeature.timeline, .transcription].contains(feature) ? "photo" : "text.alignleft")
          .font(.system(size: 11, weight: .medium)).foregroundColor(SettingsStyle.secondary)
      }
      Text(feature.map(capabilityNote) ?? String(localized: "Used by features without a custom model, and retried if a custom model fails."))
        .font(.system(size: 11)).foregroundColor(SettingsStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Model").font(.system(size: 11, weight: .medium)).foregroundColor(SettingsStyle.secondary)
          assignmentMenu(feature: feature, assignment: assignment)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 6) {
          Text("Reasoning effort").font(.system(size: 11, weight: .medium)).foregroundColor(SettingsStyle.secondary)
          if let assignment {
            effortPicker(assignment, feature: feature)
          } else {
            Text(feature == nil ? String(localized: "Provider default") : String(localized: "Use default"))
              .font(.system(size: 12)).foregroundColor(SettingsStyle.meta)
              .frame(height: 24, alignment: .leading)
          }
        }
        .frame(width: 148, alignment: .leading)
      }
      if feature != nil, assignment == nil {
        Text(configuration.defaultModel.map { String(localized: "Using default: \(assignmentTitle($0))") }
          ?? String(localized: "Choose a default model above to enable this feature."))
          .font(.system(size: 11)).foregroundColor(SettingsStyle.meta)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .background(feature == nil ? SettingsStyle.subtleFill : SettingsStyle.editorFill,
                in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsStyle.divider))
  }

  private func assignmentMenu(feature: AIFeature?, assignment: AIModelAssignment?) -> some View {
    let featureTitle = feature?.displayName ?? String(localized: "Default model")
    return Menu {
      Button(feature == nil ? String(localized: "No default model") : String(localized: "Use default")) {
        setAssignment(nil, feature: feature)
      }
      Divider()
      let connections = configuration.connections.filter(\.enabled)
      if connections.isEmpty {
        Text("Add an enabled provider and model first.")
      }
      ForEach(connections) { connection in
        Section(connection.name) {
          if connection.models.isEmpty { Text("Add models in the provider connection first.") }
          ForEach(connection.models) { model in
            Button(model.name) {
              setAssignment(AIModelAssignment(connectionID: connection.id, modelID: model.id), feature: feature)
            }
          }
        }
      }
    } label: {
      Text(assignment.map { assignmentTitle($0) }
        ?? (feature == nil ? String(localized: "Choose a model") : String(localized: "Use default")))
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .menuStyle(.borderedButton)
    .accessibilityLabel(String(localized: "Model for \(featureTitle)"))
  }

  private func effortPicker(_ assignment: AIModelAssignment, feature: AIFeature?) -> some View {
    let model = configuration.connections.first(where: { $0.id == assignment.connectionID })?
      .models.first(where: { $0.id == assignment.modelID })
    let choices = model?.reasoningChoices ?? []
    let title = feature?.displayName ?? String(localized: "Default model")
    let binding = Binding<String>(
      get: { assignment.effort ?? "" },
      set: { value in
        var changed = assignment
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        changed.effort = trimmed.isEmpty ? nil : trimmed
        setAssignment(changed, feature: feature)
      })
    if model?.reasoningChoices == nil && model?.supportsReasoning != false {
      return AnyView(TextField(String(localized: "Provider default"), text: binding)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(String(localized: "Reasoning effort for \(title)"))
        .help(String(localized: "Leave blank for the provider default, or enter a supported effort. Validate to check support.")))
    }
    return AnyView(Picker(String(localized: "Reasoning effort"), selection: binding) {
      Text("Provider default").tag("")
      ForEach(choices, id: \.self) { effort in Text(effortTitle(effort)).tag(effort) }
      if let effort = assignment.effort, !choices.contains(effort) {
        Text("\(effort) (unavailable)").tag(effort)
      }
    }
    .labelsHidden().pickerStyle(.menu)
    .accessibilityLabel(String(localized: "Reasoning effort for \(title)"))
    .disabled(choices.isEmpty && assignment.effort == nil)
    .help(model?.supportsReasoning == false
      ? String(localized: "This model does not support reasoning effort.")
      : String(localized: "Only reasoning levels reported by this provider are listed.")))
  }

  private var validationPanel: some View {
    SettingsSection(
      title: String(localized: "Validate configuration"),
      subtitle: String(localized: "Checks every feature with its effective model, including features using the default. Each check verifies that feature’s input and output.")
    ) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          if validator.running {
            ProgressView().controlSize(.small)
            Text("Validating configuration…").font(.system(size: 12))
            Spacer()
            Button(String(localized: "Cancel")) { validator.cancel() }
          } else {
            Text(hasChanges ? String(localized: "Save your changes before validating.")
                 : String(localized: "Validation results clear when the configuration changes."))
              .font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
            Spacer()
            Button(String(localized: "Validate all features")) {
              Task { await validator.validate(configuration: configuration) }
            }
            .buttonStyle(.bordered)
            .disabled(!loaded || hasChanges)
          }
        }
        ForEach(validator.results) { result in
          HStack(alignment: .top, spacing: 9) {
            validationIcon(result.status)
            VStack(alignment: .leading, spacing: 3) {
              Text(result.feature.displayName)
                .font(.system(size: 12, weight: .medium))
              Text(result.assignment.map(assignmentTitle) ?? String(localized: "No model assigned")).font(.system(size: 11))
                .foregroundColor(SettingsStyle.secondary)
              if !result.reason.isEmpty {
                Text(result.reason).font(.system(size: 11)).foregroundColor(SettingsStyle.secondary)
                  .textSelection(.enabled)
              }
            }
            Spacer()
          }
          .padding(.vertical, 5)
        }
      }
    }
  }

  @ViewBuilder private func validationIcon(_ status: AIConfigurationValidationStatus) -> some View {
    switch status {
    case .passed: Image(systemName: "checkmark.circle.fill").foregroundColor(SettingsStyle.statusGood)
    case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(SettingsStyle.destructive)
    case .running: ProgressView().controlSize(.small)
    case .pending: Image(systemName: "circle.dotted").foregroundColor(SettingsStyle.meta)
    case .cancelled: Image(systemName: "minus.circle").foregroundColor(SettingsStyle.meta)
    }
  }

  private func assignmentTitle(_ assignment: AIModelAssignment?) -> String {
    guard let assignment else { return String(localized: "Choose a connection and model") }
    guard let connection = configuration.connections.first(where: { $0.id == assignment.connectionID }) else {
      return String(localized: "Connection deleted") + " · " + assignment.modelID
    }
    return connection.name + (connection.enabled ? "" : String(localized: " (disabled)"))
      + " / " + assignment.modelID
  }

  private func setAssignment(_ value: AIModelAssignment?, feature: AIFeature?) {
    if let feature {
      configuration.routes[feature] = value.map { AIFeatureRoute(primary: $0) }
    } else {
      configuration.defaultModel = value
    }
  }

  private func effortTitle(_ value: String) -> String {
    switch value {
    case "none": return String(localized: "None")
    case "minimal": return String(localized: "Minimal")
    case "low": return String(localized: "Low")
    case "medium": return String(localized: "Medium")
    case "high": return String(localized: "High")
    case "max": return String(localized: "Maximum")
    case "xhigh": return String(localized: "Extra high")
    case "ultra": return String(localized: "Ultra")
    default: return value
    }
  }

  private func featureIcon(_ feature: AIFeature) -> String {
    switch feature {
    case .timeline: return "clock"
    case .targetEvaluation: return "target"
    case .transcription: return "text.viewfinder"
    case .activityCards: return "rectangle.stack"
    case .text: return "text.alignleft"
    }
  }

  private func capabilityNote(_ feature: AIFeature) -> String {
    switch feature {
    case .timeline: return String(localized: "Screenshots → final activity cards in one call, including titles, summaries, and minute-by-minute details. Requires image input.")
    case .targetEvaluation: return String(localized: "Checks how recent activities align with your current goals.")
    case .transcription: return String(localized: "Split path, step 1: screenshots → timestamped observations. These are intermediate evidence, not the card details displayed on the timeline.")
    case .activityCards: return String(localized: "Split path, step 2: observations → final activity cards, including titles, summaries, and minute-by-minute details. This model does not receive screenshots.")
    case .text: return String(localized: "Generates text from the context supplied by the app.")
    }
  }

  private func emptyState(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 13, weight: .medium))
      Text(detail).font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(SettingsStyle.editorFill, in: RoundedRectangle(cornerRadius: 8))
  }

  private func deletionSummary(_ connection: AIProviderConnection) -> String {
    var uses = AIFeature.allCases.filter {
      configuration.routes[$0]?.primary.connectionID == connection.id
    }.map(\.displayName)
    if configuration.defaultModel?.connectionID == connection.id {
      uses.insert(String(localized: "Default model"), at: 0)
    }
    if uses.isEmpty { return String(localized: "This connection has no model assignments. Save after deleting it.") }
    return String(localized: "Used by: \(uses.joined(separator: ", ")). Deleting this connection clears these selections. Features without a custom model use the default model.")
  }

  private func removeConnection(_ connection: AIProviderConnection) {
    configuration.connections.removeAll { $0.id == connection.id }
    if configuration.defaultModel?.connectionID == connection.id { configuration.defaultModel = nil }
    for feature in AIFeature.allCases where configuration.routes[feature]?.primary.connectionID == connection.id {
      configuration.routes[feature] = nil
    }
  }

  private func load() {
    guard !loaded else { return }
    do {
      configuration = try AIConfigurationStore.shared.load()
      savedConfiguration = configuration
      loaded = true
    } catch {
      isError = true
      status = error.localizedDescription
    }
  }

  private func save() {
    do {
      try AIConfigurationStore.shared.save(configuration)
      savedConfiguration = configuration
      isError = false
      status = String(localized: "Configuration saved")
    } catch {
      isError = true
      status = error.localizedDescription
    }
  }
}

private enum AIConnectionPreset: String, CaseIterable, Identifiable {
  case openRouter, openAI, deepSeek, kimi, custom, gemini, ollama, lmStudio, claude, codex
  var id: String { rawValue }
  var title: String {
    switch self {
    case .openRouter: return "OpenRouter"
    case .openAI: return "OpenAI"
    case .deepSeek: return "DeepSeek"
    case .kimi: return "Kimi"
    case .custom: return String(localized: "Custom API")
    case .gemini: return "Gemini API"
    case .ollama: return "Ollama"
    case .lmStudio: return "LM Studio"
    case .claude: return String(localized: "Claude subscription CLI")
    case .codex: return String(localized: "Codex subscription CLI")
    }
  }
  var connection: AIProviderConnection {
    switch self {
    case .openRouter: return AIProviderConnection(name: title, kind: .openAICompatible, endpoint: "https://openrouter.ai/api/v1")
    case .openAI: return AIProviderConnection(name: title, kind: .openAICompatible, endpoint: "https://api.openai.com/v1")
    case .deepSeek: return AIProviderConnection(name: title, kind: .openAICompatible, endpoint: "https://api.deepseek.com/v1")
    case .kimi: return AIProviderConnection(name: title, kind: .openAICompatible, endpoint: "https://api.moonshot.cn/v1")
    case .custom: return AIProviderConnection(name: title, kind: .openAICompatible, endpoint: "https://")
    case .gemini: return AIProviderConnection(name: title, kind: .gemini, endpoint: "https://generativelanguage.googleapis.com")
    case .ollama: return AIProviderConnection(name: title, kind: .local, endpoint: "http://localhost:11434", localEngine: "ollama")
    case .lmStudio: return AIProviderConnection(name: title, kind: .local, endpoint: "http://localhost:1234/v1", localEngine: "lmstudio")
    case .claude: return AIProviderConnection(name: title, kind: .claudeCLI)
    case .codex: return AIProviderConnection(name: title, kind: .codexCLI)
    }
  }
}

private struct AIConnectionEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var connection: AIProviderConnection
  let onCLISetup: (AIProviderKind) -> Void
  let onSave: (AIProviderConnection, String?) throws -> Void
  @State private var secret = ""
  @State private var replaceSecret = false
  @State private var newModel = ""
  @State private var error: String?
  @State private var discovering = false
  @State private var discoveryTask: Task<Void, Never>?

  private var isCLI: Bool { connection.kind == .claudeCLI || connection.kind == .codexCLI }
  private var hasSecret: Bool { AIConfigurationStore.shared.secret(for: connection) != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Provider connection").font(.system(size: 19, weight: .semibold))
          Text(connection.kind.displayName).font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
        }
        Spacer()
        Toggle(String(localized: "Enabled"), isOn: $connection.enabled).toggleStyle(.switch).controlSize(.small)
      }
      Form {
        TextField(String(localized: "Name"), text: $connection.name)
          .accessibilityLabel(String(localized: "Connection name"))
        if !isCLI {
          TextField(String(localized: "API endpoint"), text: Binding(
            get: { connection.endpoint ?? "" }, set: { connection.endpoint = $0 }))
            .accessibilityLabel(String(localized: "API endpoint"))
          if hasSecret {
            Toggle(String(localized: "Replace saved API key"), isOn: $replaceSecret)
          }
          if !hasSecret || replaceSecret {
            SecureField(String(localized: "API key"), text: $secret)
              .accessibilityLabel(String(localized: "API key"))
          }
        }
      }
      .textFieldStyle(.roundedBorder)
      if isCLI {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "terminal").foregroundColor(SettingsStyle.ink)
          Text("Uses the local CLI sign-in. Connections of the same kind share that sign-in, even when added separately.")
            .font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
          Spacer()
          Button(String(localized: "Configure CLI")) { onCLISetup(connection.kind) }
        }
      }
      Divider()
      HStack {
        Text("Available models").font(.system(size: 13, weight: .semibold))
        Spacer()
        if discovering { ProgressView().controlSize(.small) }
        Button(isCLI ? String(localized: "Read CLI models") : String(localized: "Discover models"), action: discover)
          .disabled(discovering)
      }
      ScrollView {
        VStack(spacing: 0) {
          if connection.models.isEmpty {
            Text("Discover models or add a model ID below.")
              .font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(12)
          }
          ForEach(connection.models) { model in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.system(size: 12, weight: .medium))
                if model.name != model.id {
                  Text(model.id).font(.system(size: 11)).foregroundColor(SettingsStyle.secondary)
                }
                Text(model.reasoningChoices?.joined(separator: " · ")
                  ?? (model.supportsReasoning == false ? String(localized: "Reasoning effort is not supported") : String(localized: "Reasoning support unknown; uses provider default")))
                  .font(.system(size: 10)).foregroundColor(SettingsStyle.meta)
              }
              Spacer()
              Button {
                connection.models.removeAll { $0.id == model.id }
              } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help(String(localized: "Remove model"))
                .accessibilityLabel(String(localized: "Remove model \(model.id)"))
            }.padding(.vertical, 9)
            Divider()
          }
        }.padding(.horizontal, 12)
      }
      .frame(height: 180)
      .background(SettingsStyle.editorFill, in: RoundedRectangle(cornerRadius: 8))
      HStack {
        TextField(String(localized: "Enter a model ID manually"), text: $newModel)
          .textFieldStyle(.roundedBorder).onSubmit(addModel)
          .accessibilityLabel(String(localized: "Model ID"))
        Button(String(localized: "Add"), action: addModel)
          .disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let error {
        Text(error).font(.system(size: 12)).foregroundColor(SettingsStyle.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Text("Saves this connection and current feature settings. API keys are stored in local files readable only by your macOS user.")
          .font(.system(size: 11)).foregroundColor(SettingsStyle.secondary)
        Spacer()
        Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(String(localized: "Save")) {
          do {
            try onSave(connection, !isCLI && (!hasSecret || replaceSecret) ? secret : nil)
          } catch { self.error = error.localizedDescription }
        }
        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        .disabled(connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || discovering)
      }
    }
    .padding(24).frame(width: 590)
    .onDisappear { discoveryTask?.cancel() }
  }

  private func addModel() {
    let id = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, id.rangeOfCharacter(from: .controlCharacters) == nil else { return }
    if !connection.models.contains(where: { $0.id == id }) {
      connection.models.append(AIConfiguredModel(id: id))
    }
    newModel = ""
  }

  private func discover() {
    discovering = true
    error = nil
    let candidate = connection
    let credential = !hasSecret || replaceSecret ? secret : AIConfigurationStore.shared.secret(for: candidate)
    discoveryTask = Task { @MainActor in
      defer { discovering = false }
      do {
        let models = try await AIProviderDiscovery.discoverModels(for: candidate, secret: credential)
        guard !Task.isCancelled else { return }
        for discovered in models {
          if let index = connection.models.firstIndex(where: { $0.id == discovered.id }) {
            connection.models[index] = discovered
          } else { connection.models.append(discovered) }
        }
        if models.isEmpty { error = String(localized: "No models found. You can add a model ID manually.") }
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }
}

private struct AIConfigurationExample: Identifiable {
  let feature: AIFeature
  var id: String { feature.rawValue }
  var title: String { feature.displayName }
  var includesImage: Bool { [.timeline, .transcription].contains(feature) }

  var input: String {
    switch feature {
    case .timeline:
      return String(localized: "Screenshots: two images, 09:00 and 09:15, showing the synthetic report editor below.\nCategories: Work, Personal, Idle.\nPrevious cards: none.\nDescribe the activity as timeline cards with grounded timestamps and summaries.")
    case .transcription:
      return String(localized: "Screenshots: 09:00 and 09:15, showing the synthetic report editor below.\nRead the visible text and describe the activity as timestamped observations.")
    case .activityCards:
      return String(localized: "09:00–09:15: Worked on report DAYFLOW CONTEXT 8316 and completed its summary.\nCategories: Work, Personal, Idle.\nGroup these observations into an activity card.")
    case .targetEvaluation:
      return String(localized: "Current goals: Complete report DAYFLOW CONTEXT 8316.\nActivity: Finished and delivered report DAYFLOW CONTEXT 8316.\nDuration: 15 minutes. Crosses target boundary: false.\nEvaluate whether this activity advances any current goal.")
    case .text:
      return String(localized: "Extract the report title from: Completed report DAYFLOW CONTEXT 8316.\nReturn JSON with an answer field containing the exact title.")
    }
  }

  var role: String {
    switch feature {
    case .timeline:
      return String(localized: "DIRECT PATH\nScreenshots → final activity cards\n\nThis single call produces the title, summary, and detailedSummary shown on the timeline. Screenshots are sent directly to the Timeline model. It returns complete cards in one call; there is no separate transcription or card-generation model.")
    case .transcription:
      return String(localized: "SPLIT PATH · STEP 1\nScreenshots → observations → Activity cards model\n\nEach observation records what was visible during an interval. It is intermediate evidence. It does not yet choose the final card title, category, grouping, or detailedSummary.")
    case .activityCards:
      return String(localized: "SPLIT PATH · STEP 2\nObservations from Transcription → final activity cards\n\nThis call groups evidence and writes title, summary, and detailedSummary. The minute-by-minute lines visible in a card’s detailed view come from detailedSummary. Screenshots are not sent to this model.")
    default:
      return String(localized: "Activity title and summary + current goals → alignment result. This call evaluates existing activity text; it does not read screenshots or generate timeline cards.")
    }
  }

  var request: String {
    switch feature {
    case .timeline, .transcription:
      return """
        {
          "screenshots": [
            {"capturedAt": "09:00", "image": "<image attachment 1>"},
            {"capturedAt": "09:15", "image": "<image attachment 2>"}
          ]\(feature == .timeline ? ",\n  \"categories\": [\"Work\", \"Personal\", \"Idle\"],\n  \"existingCards\": []" : "")
        }
        """
    case .activityCards:
      return """
        {
          "observations": [{
            "startTime": "09:00", "endTime": "09:15",
            "observation": "Report editor visible. Read the draft, revised the main section, then checked the summary of DAYFLOW CONTEXT 8316."
          }],
          "categories": ["Work", "Personal", "Idle"],
          "existingCards": []
        }
        """
    case .targetEvaluation:
      return """
        {
          "currentGoals": [{"name": "Complete report DAYFLOW CONTEXT 8316"}],
          "title": "Completed report DAYFLOW CONTEXT 8316",
          "summary": "Finished and delivered the requested report.",
          "durationMinutes": 15,
          "crossesTargetBoundary": false
        }
        """
    default: return input
    }
  }

  var checks: String {
    switch feature {
    case .timeline:
      return String(localized: "The images must be read successfully. Output must contain activity cards with a title, category, nonempty summary, and a valid time interval. The image marker must appear in the card content.")
    case .transcription:
      return String(localized: "Output must contain timestamped observations with endTs greater than startTs. The visible image marker must appear in an observation; an HTTP success alone does not pass.")
    case .activityCards:
      return String(localized: "Output must contain activity cards with valid time intervals, titles, categories, and summaries. The report title from the observations must be preserved. Enabled custom card instructions also apply.")
    case .targetEvaluation:
      return String(localized: "Output must be JSON with alignment, reason, and reminder. For this completed goal, alignment must be focused, reason must name the report, and reminder must be empty.")
    default: return ""
    }
  }

  // Representative response fields match the app's prompts; providers serialize requests differently.
  var output: String {
    switch feature {
    case .timeline, .activityCards:
      return """
        [
          {
            "startTime": "9:00 AM",
            "endTime": "9:15 AM",
            "category": "Work",
            "subcategory": "Writing",
            "title": "Working on the validation report",
            "summary": "Worked on report DAYFLOW \(feature == .timeline ? "VISION 4729" : "CONTEXT 8316").",
            "detailedSummary": "9:00 AM - 9:05 AM: Read the report draft.\\n9:05 AM - 9:10 AM: Revised the main section.\\n9:10 AM - 9:15 AM: Checked the report summary.",
            "distractions": [],
            "appSites": {"primary": "Report editor", "secondary": ""}
          }
        ]
        """
    case .transcription:
      return """
        [
          {
            "startTs": 1700000000,
            "endTs": 1700000900,
            "observation": "Report editor visible with DAYFLOW VISION 4729. Read the draft, revised the main section, then checked the summary."
          }
        ]
        """
    case .targetEvaluation:
      return """
        {
          "alignment": "focused",
          "reason": "Completed report DAYFLOW CONTEXT 8316, advancing the report goal.",
          "reminder": ""
        }
        """
    case .text:
      return "{\"answer\": \"DAYFLOW CONTEXT 8316\"}"
    }
  }
}

private struct AIConfigurationExampleSheet: View {
  @Environment(\.dismiss) private var dismiss
  let example: AIConfigurationExample

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(example.title).font(.system(size: 19, weight: .semibold))
          Text("How this feature uses AI").font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
        }
        Spacer()
        Button(String(localized: "Done")) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel(String(localized: "Close examples"))
      }
      Text("Illustrative synthetic data only. Requests include additional instructions, and formatting varies by provider. No request is sent and no personal data is used.")
        .font(.system(size: 12)).foregroundColor(SettingsStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          exampleBlock(String(localized: "Where this step fits"), text: example.role)
          exampleBlock(String(localized: "1. Input sent by the app"), text: example.input)
          if example.includesImage {
            VStack(alignment: .leading, spacing: 8) {
              Label(String(localized: "Synthetic screenshot input"), systemImage: "photo")
                .font(.system(size: 12, weight: .semibold))
              VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "Report editor · Validation report"), systemImage: "doc.text")
                  .font(.system(size: 11)).foregroundColor(SettingsStyle.secondary)
                Divider()
                Text("DAYFLOW VISION 4729")
                  .font(.system(size: 21, weight: .semibold, design: .monospaced))
                Text("Working on a validation report.\nSummary: completed the report draft.")
                  .font(.system(size: 12, design: .monospaced))
              }
              .padding(18).frame(maxWidth: .infinity, alignment: .leading)
              .background(SettingsStyle.surface, in: RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsStyle.divider))
              .textSelection(.enabled)
              .accessibilityLabel(String(localized: "Synthetic report screen showing DAYFLOW VISION 4729"))
            }
          }
          exampleBlock(String(localized: "2. Request data"), text: example.request)
          Text("Field names and image encoding vary by provider. This shows the feature data, not a copyable HTTP request.")
            .font(.system(size: 11)).foregroundColor(SettingsStyle.secondary)
          exampleBlock(String(localized: "3. Expected structured output"), text: example.output)
          if example.feature == .timeline || example.feature == .activityCards {
            exampleBlock(String(localized: "Card details shown to you · detailedSummary"),
              text: String(localized: "09:00–09:05: Read the report draft.\n09:05–09:10: Revised the main section.\n09:10–09:15: Checked the report summary."))
          }
          exampleBlock(String(localized: "4. What validation checks"), text: example.checks)
        }
        .padding(.trailing, 6)
      }
    }
    .padding(24).frame(width: 720, height: 740)
    .foregroundColor(SettingsStyle.text)
    .background(SettingsStyle.canvas)
  }

  private func exampleBlock(_ title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 12, weight: .semibold))
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SettingsStyle.editorFill, in: RoundedRectangle(cornerRadius: 8))
    }
  }
}
