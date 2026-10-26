import SwiftUI

struct TargetView: View {
  @ObservedObject private var store = TargetStore.shared
  @State private var draft = ""

  private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Target")
            .font(.custom("InstrumentSerif-Regular", size: 32))
          Text("设定此刻的目标，让每张活动卡片帮你检查方向。")
            .font(.custom("Figtree", size: 14))
            .foregroundStyle(SettingsStyle.secondary)
        }

        SettingsSection(title: "当前目标", subtitle: "写清楚要完成的事情，也可以注明允许的准备工作和休息。") {
          VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $draft)
              .font(.custom("Figtree", size: 15))
              .scrollContentBackground(.hidden)
              .padding(10)
              .frame(height: 110)
              .background(SettingsStyle.editorFill)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(SettingsStyle.editorBorder))
              .accessibilityLabel("当前目标")
            HStack {
              Text("例如：完成登录页，允许查阅 SwiftUI 文档。")
                .font(.custom("Figtree", size: 12))
                .foregroundStyle(SettingsStyle.secondary)
              Spacer()
              Text("\(draft.count)/1000")
                .font(.custom("Figtree", size: 12))
                .foregroundStyle(SettingsStyle.meta)
            }
            HStack(spacing: 12) {
              SettingsPrimaryButton(
                title: store.target == nil ? "开始专注" : "更新目标",
                isDisabled: trimmedDraft.isEmpty || draft.count > 1000
                  || trimmedDraft == store.target?.text
              ) {
                store.setTarget(trimmedDraft)
              }

              if store.target != nil {
                SettingsSecondaryButton(title: "结束目标") { store.clearTarget() }
              }
              Spacer()
            }
            if let target = store.target {
              Text("正在评估：\(target.text)")
                .font(.custom("Figtree", size: 13))
              Text(
                "开始于 \(target.startedAt.formatted(date: .abbreviated, time: .shortened)) · 仅评估目标生效后的活动片段"
              )
              .font(.custom("Figtree", size: 12))
              .foregroundStyle(SettingsStyle.secondary)
            } else {
              Text("尚未启用目标。开始后，新生成的卡片会自动进行 AI 评估。")
                .font(.custom("Figtree", size: 13))
                .foregroundStyle(SettingsStyle.secondary)
            }
          }
        }

        SettingsSection(title: "评估规则") {
          VStack(alignment: .leading, spacing: 10) {
            Label("专心：当前活动直接推进目标，或属于必要的准备。", systemImage: "checkmark.circle")
            Label("中性：关联不明确、短暂切换或合理休息。", systemImage: "minus.circle")
            Label("严重偏离：有明确证据表明主要活动持续偏离目标。", systemImage: "exclamationmark.triangle")
            Text("严重偏离时，AI 会给出一个具体的回归建议。提醒开关、间隔和系统权限可在设置 → Target 中调整。AI 判断可能有误，仅供参考。")
              .foregroundStyle(SettingsStyle.secondary)
          }
          .font(.custom("Figtree", size: 13))
        }

        SettingsSection(title: "最近评估", subtitle: "显示当前目标的最近 50 张卡片；卡片详情保留评估时的目标和理由。") {
          VStack(alignment: .leading, spacing: 16) {
            if store.isEvaluating {
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在评估新卡片…")
              }
              .font(.custom("Figtree", size: 13))
            }
            if let error = store.lastError {
              Text(error)
                .font(.custom("Figtree", size: 13))
                .foregroundStyle(SettingsStyle.destructive)
              SettingsSecondaryButton(title: "重试评估") { store.retryPendingEvaluations() }
            }
            if store.currentAssessments.isEmpty && !store.isEvaluating {
              Text("等待目标生效后的第一张活动卡片。评估会在卡片生成后完成。")
                .font(.custom("Figtree", size: 13))
                .foregroundStyle(SettingsStyle.secondary)
            }
            ForEach(store.currentAssessments) { assessment in
              VStack(alignment: .leading, spacing: 8) {
                Text(assessment.cardTitle)
                  .font(.custom("Figtree", size: 15).weight(.semibold))
                Text(
                  "\(assessment.startTime.formatted(date: .omitted, time: .shortened)) – \(assessment.endTime.formatted(date: .omitted, time: .shortened))"
                )
                .font(.custom("Figtree", size: 12))
                .foregroundStyle(SettingsStyle.secondary)
                TargetAssessmentView(assessment: assessment, showsTarget: false)
              }
              Divider().overlay(SettingsStyle.divider)
            }
          }
        }
      }
      .foregroundStyle(SettingsStyle.text)
      .frame(maxWidth: 720, alignment: .leading)
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .onAppear { draft = store.target?.text ?? "" }
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
        Text("评估目标：\(assessment.targetText)")
          .font(.custom("Figtree", size: 12))
          .foregroundStyle(SettingsStyle.secondary)
      }
      Text(assessment.reason)
        .font(.custom("Figtree", size: 13))
      if assessment.alignment == .severe && !assessment.reminder.isEmpty {
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
