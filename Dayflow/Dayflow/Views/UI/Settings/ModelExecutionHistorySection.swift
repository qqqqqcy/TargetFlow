import SwiftUI

struct ModelExecutionHistorySection: View {
  var body: some View {
    // Poll background request metadata on the main actor without observing worker updates.
    TimelineView(.periodic(from: .now, by: 2)) { _ in
      SettingsSection(
        title: String(localized: "Recent model calls"),
        subtitle: String(localized: "Recent execution metadata only. Prompts and responses are never stored here.")
      ) {
        let records = ModelExecutionHistory.shared.records
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(String(localized: "Latest 50 calls"))
              .foregroundColor(SettingsStyle.secondary)
            Spacer()
            Button(String(localized: "Clear history")) { ModelExecutionHistory.shared.clear() }
              .disabled(records.isEmpty)
              .accessibilityLabel(String(localized: "Clear model call history"))
          }
          if records.isEmpty {
            Text(String(localized: "No model calls recorded yet."))
              .foregroundColor(SettingsStyle.secondary)
              .padding(.vertical, 8)
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(records) { record in
                  historyRow(record)
                }
              }
              .padding(1)
            }
            .frame(height: min(CGFloat(records.count) * 162, 300))
            .accessibilityLabel(String(localized: "Recent model call history"))
          }
        }
        .font(.system(size: 12))
        .foregroundColor(SettingsStyle.text)
      }
    }
  }

  private func reasoningTitle(_ value: String?) -> String {
    switch value {
    case nil, "default", "providerDefault": return String(localized: "Provider default")
    case "none", "disabled": return String(localized: "None")
    case "minimal": return String(localized: "Minimal")
    case "low": return String(localized: "Low")
    case "medium": return String(localized: "Medium")
    case "high": return String(localized: "High")
    case "xhigh": return String(localized: "Extra high")
    case "max": return String(localized: "Maximum")
    case "ultra": return String(localized: "Ultra")
    case .some(let value): return value
    }
  }

  private func historyRow(_ record: ModelExecutionRecord) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Text(record.provider).fontWeight(.semibold)
        Spacer()
        Label(
          record.outcome == .succeeded ? String(localized: "Succeeded") : String(localized: "Failed"),
          systemImage: record.outcome == .succeeded ? "checkmark.circle" : "xmark.circle")
          .foregroundColor(record.outcome == .failed ? SettingsStyle.destructive : SettingsStyle.statusGood)
        Text(record.finishedAt, style: .time).foregroundColor(SettingsStyle.secondary)
      }
      Text("Model: \(record.requestedModel ?? String(localized: "Provider default"))")
      Text("Reasoning effort: \(reasoningTitle(record.requestedReasoning))")
        .foregroundColor(SettingsStyle.secondary)
      let differentModels = record.reportedModels.filter { $0 != record.requestedModel }
      if !differentModels.isEmpty {
        Text("Returned model: \(differentModels.joined(separator: ", "))")
          .foregroundColor(SettingsStyle.secondary)
      }
      if let returned = record.reportedReasoning, returned != record.requestedReasoning {
        Text("Returned reasoning effort: \(reasoningTitle(returned))")
          .foregroundColor(SettingsStyle.secondary)
      }
      if let failure = record.failureCode {
        Text("Failure: \(failure)").foregroundColor(SettingsStyle.destructive)
      }
      Text("\(record.startedAt.formatted(date: .abbreviated, time: .standard)) · \(String(format: "%.1f", max(0, record.finishedAt.timeIntervalSince(record.startedAt))))s")
        .foregroundColor(SettingsStyle.meta)
    }
    .font(.system(size: 11))
    .textSelection(.enabled)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SettingsStyle.editorFill, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsStyle.divider))
  }
}
