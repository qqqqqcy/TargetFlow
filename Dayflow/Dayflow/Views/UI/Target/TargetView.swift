import SwiftUI

/// Goals remain event settings; this banner exposes the active set on the timeline.
struct CurrentGoalsStatusView: View {
  @ObservedObject private var store = TargetStore.shared
  @EnvironmentObject private var categoryStore: CategoryStore
  @Environment(\.dayflowTheme) private var theme
  let onManageEvents: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Image("TargetFlowLogo")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 24, height: 24)
          .foregroundStyle(theme.accent)
          .frame(width: 38, height: 38)
          .background(theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          Text(
            categoryStore.currentTargets.isEmpty
              ? String(localized: "No current goals enabled")
              : String(localized: "Current goals: \(categoryStore.currentTargets.map(\.name).joined(separator: String(localized: ", ")))")
          )
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(theme.textPrimary)
          .lineLimit(2)
          .help(categoryStore.currentTargets.map(\.name).joined(separator: String(localized: ", ")))

          Text(
            categoryStore.currentTargets.isEmpty
              ? String(localized: "Enable an event’s goal switch to assess focus in new recordings.")
              : String(localized: "Making progress toward any enabled goal counts as focused.")
          )
          .font(.system(size: 11))
          .foregroundStyle(theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if store.isEvaluating {
          ProgressView().controlSize(.small)
            .help(String(localized: "Assessing new events"))
        }
        Button(action: onManageEvents) {
          Label(String(localized: "Events & Goals"), systemImage: "slider.horizontal.3")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.primaryButtonText)
            .padding(.horizontal, DayflowLayout.buttonHorizontalInset)
            .frame(height: DayflowLayout.buttonHeight)
            .background(
              theme.primaryButtonFill, in: RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius))
            .overlay(
              RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius).stroke(theme.primaryButtonBorder))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityHint(String(localized: "Manage events and use the switches to choose any number of current goals"))
        .fixedSize()
      }
      if let error = store.lastError {
        HStack(alignment: .top, spacing: 10) {
          Label(error, systemImage: "exclamationmark.circle")
            .foregroundStyle(SettingsStyle.destructive)
          DayflowButton(title: String(localized: "Retry assessment"), action: { store.retryPendingEvaluations() }, isSubtle: true)
            .fixedSize()
        }
        .font(.system(size: 12))
      }
    }
    .padding(14)
    .background(theme.rightPanelFill, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.rightPanelBorder, lineWidth: 1))
  }
}

struct TargetAssessmentView: View {
  @Environment(\.dayflowTheme) private var theme
  let assessment: TargetAssessment
  var showsTarget = true

  private var statusColor: Color {
    switch assessment.alignment {
    case .focused: return theme.accent
    case .neutral: return theme.textSecondary
    case .severe: return theme.isDark ? Color(hex: "E99C91") : Color(hex: "B95F54")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label(String(localized: "Goal assessment: \(assessment.alignment.title)"), systemImage: assessment.alignment.symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(statusColor)
      Text(assessment.reason)
        .font(.system(size: 12))
        .foregroundStyle(theme.textSecondary)
        .lineSpacing(3)
      if assessment.alignment != .focused && !assessment.reminder.isEmpty {
        Text(assessment.reminder)
          .font(.system(size: 12))
          .foregroundStyle(theme.textPrimary)
          .lineSpacing(3)
      }
      if showsTarget {
        Text(String(localized: "Goals at assessment: \(assessment.targetText)"))
          .font(.system(size: 11))
          .foregroundStyle(theme.textTertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .padding(12)
    .background(
      statusColor.opacity(theme.isDark ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(statusColor.opacity(0.15), lineWidth: 1))
  }
}
