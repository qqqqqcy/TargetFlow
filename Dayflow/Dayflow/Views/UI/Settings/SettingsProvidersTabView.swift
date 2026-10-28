import AppKit
import SwiftUI

struct SettingsProvidersTabView: View {
  @ObservedObject var viewModel: ProvidersSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {

      if let error = viewModel.providerRoutingErrorMessage {
        Text(error)
          .font(.system(size: 13))
          .foregroundColor(SettingsStyle.destructive)
      }

      AIConfigurationSettingsView(viewModel: viewModel)
      ModelExecutionHistorySection()

      sharedPromptCustomizationSection
    }
  }

  // MARK: - Prompt customization

  private var sharedPromptCustomizationSection: some View {
    let defaults = (
      titleBlock: CodexPromptDefaults.titleBlock,
      summaryBlock: CodexPromptDefaults.summaryBlock,
      detailedSummaryBlock: CodexPromptDefaults.detailedSummaryBlock
    )
    return promptSection(
      title: String(localized: "Activity-card prompt customization"),
      subtitle: String(
        localized: "Customize card titles, summaries, and detailed summaries for all configured providers."),
      intro:
        String(
          localized:
            "Enabled instructions apply to every provider and model. Disabled sections use each provider's defaults."
        ),
      sections: [
        promptEditorConfig(
          heading: String(localized: "Card titles"),
          description: String(localized: "Shape how card titles read and tweak the example list."),
          isEnabled: $viewModel.useCustomTitlePrompt,
          text: $viewModel.titlePromptText,
          defaultText: defaults.titleBlock
        ),
        promptEditorConfig(
          heading: String(localized: "Card summaries"),
          description: String(localized: "Control tone and style for the summary field."),
          isEnabled: $viewModel.useCustomSummaryPrompt,
          text: $viewModel.summaryPromptText,
          defaultText: defaults.summaryBlock
        ),
        promptEditorConfig(
          heading: String(localized: "Detailed summaries"),
          description: String(
            localized: "Define the minute-by-minute breakdown format and examples."),
          isEnabled: $viewModel.useCustomDetailedPrompt,
          text: $viewModel.detailedPromptText,
          defaultText: defaults.detailedSummaryBlock
        ),
      ],
      onReset: viewModel.resetSharedPromptOverrides
    )
  }

  private struct PromptEditorConfig {
    let heading: String
    let description: String
    let isEnabled: Binding<Bool>
    let text: Binding<String>
    let defaultText: String
  }

  private func promptEditorConfig(
    heading: String,
    description: String,
    isEnabled: Binding<Bool>,
    text: Binding<String>,
    defaultText: String
  ) -> PromptEditorConfig {
    PromptEditorConfig(
      heading: heading, description: description, isEnabled: isEnabled, text: text,
      defaultText: defaultText)
  }

  private func promptSection(
    title: String,
    subtitle: String,
    intro: String,
    sections: [PromptEditorConfig],
    onReset: @escaping () -> Void
  ) -> some View {
    SettingsSection(title: title, subtitle: subtitle) {
      VStack(alignment: .leading, spacing: 18) {
        Text(intro)
          .font(.system(size: 12))
          .foregroundColor(SettingsStyle.secondary)
          .fixedSize(horizontal: false, vertical: true)

        ForEach(sections.indices, id: \.self) { index in
          promptEditorBlock(config: sections[index])
        }

        HStack {
          Spacer()
          SettingsSecondaryButton(
            title: String(localized: "Reset to Target Flow defaults"),
            systemImage: "arrow.counterclockwise",
            action: onReset
          )
        }
      }
    }
  }

  /// A prompt-customization block: toggle + text-editor pair. Keeps its
  /// own subtle container because the text editor needs input-affordance
  /// against the paper background.
  private func promptEditorBlock(config: PromptEditorConfig) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(isOn: config.isEnabled) {
        VStack(alignment: .leading, spacing: 3) {
          Text(config.heading)
            .font(.system(size: 14))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text(config.description)
            .font(.system(size: 12))
            .foregroundColor(SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(SwitchToggleStyle(tint: SettingsStyle.ink))
      .pointingHandCursor()

      ZStack(alignment: .topLeading) {
        if config.text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(config.defaultText)
            .font(.system(size: 12))
            .foregroundColor(SettingsStyle.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
        }

        TextEditor(text: config.text)
          .font(.system(size: 12))
          .foregroundColor(
            config.isEnabled.wrappedValue ? SettingsStyle.text : SettingsStyle.secondary
          )
          .scrollContentBackground(.hidden)
          .disabled(!config.isEnabled.wrappedValue)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(minHeight: config.isEnabled.wrappedValue ? 140 : 120)
      }
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(SettingsStyle.editorFill)
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(SettingsStyle.editorBorder, lineWidth: 1)
          )
      )
    }
  }
}
