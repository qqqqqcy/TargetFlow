import SwiftUI

/// A compact entry point beside the event timeline; goals live in event settings.
struct CurrentGoalsStatusView: View {
  @ObservedObject private var store = TargetStore.shared
  @EnvironmentObject private var categoryStore: CategoryStore
  let onManageEvents: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Button(action: onManageEvents) {
          Label("事件与目标", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityHint("管理事件，并通过开关选择任意多个当前目标")

        Text(
          categoryStore.currentTargets.isEmpty
            ? "未开启当前目标"
            : "当前目标：" + categoryStore.currentTargets.map(\.name).joined(separator: "、")
        )
        .foregroundStyle(SettingsStyle.secondary)
        .lineLimit(2)
        .help(categoryStore.currentTargets.map(\.name).joined(separator: "、"))
        Spacer(minLength: 0)
        if store.isEvaluating {
          ProgressView().controlSize(.small)
            .help("正在评估新事件")
        }
      }
      if let error = store.lastError {
        HStack {
          Text(error).foregroundStyle(SettingsStyle.destructive)
          Button("重试评估") { store.retryPendingEvaluations() }
            .buttonStyle(.plain)
        }
      }
    }
    .font(.custom("Figtree", size: 12))
    .foregroundStyle(SettingsStyle.text)
  }
}

struct TargetAssessmentView: View {
  let assessment: TargetAssessment
  var showsTarget = true

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(assessment.alignment.title, systemImage: assessment.alignment.symbol)
        .font(.custom("Figtree", size: 13).weight(.semibold))
      if showsTarget {
        Text("评估时的目标：\(assessment.targetText)")
          .font(.custom("Figtree", size: 12))
          .foregroundStyle(SettingsStyle.secondary)
      }
      Text(assessment.reason)
        .font(.custom("Figtree", size: 13))
      if assessment.alignment != .focused && !assessment.reminder.isEmpty {
        Text(assessment.reminder)
          .font(.custom("Figtree", size: 13))
          .foregroundStyle(SettingsStyle.ink)
      }
    }
    .foregroundStyle(SettingsStyle.text)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}
