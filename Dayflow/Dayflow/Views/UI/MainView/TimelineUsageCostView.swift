import SwiftUI

extension Notification.Name {
  static let llmUsageUpdated = Notification.Name("llmUsageUpdated")
}

struct TimelineUsageCostView: View {
  @Environment(\.dayflowTheme) private var theme
  @State private var summary: LLMUsageSummary?
  @State private var refreshID = 0
  @State private var showsDetails = false

  var body: some View {
    Button {
      showsDetails.toggle()
    } label: {
      Text("· " + (summary?.costText ?? "累计费用 —"))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .help(summary?.detailText ?? "暂时无法读取累计费用")
    .popover(isPresented: $showsDetails, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 12) {
        Label("接口用量与费用", systemImage: "chart.bar.doc.horizontal")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(theme.textPrimary)
        Rectangle().fill(theme.rightPanelDivider).frame(height: 1)
        Text(summary?.detailText ?? "暂时无法读取累计费用")
          .font(.system(size: 12))
          .foregroundStyle(theme.textSecondary)
          .lineSpacing(4)
          .textSelection(.enabled)
      }
      .frame(width: 310, alignment: .leading)
      .padding(18)
      .background(theme.popoverFill)
    }
    .task(id: refreshID) {
      let loaded = await Task.detached(priority: .utility) {
        try? StorageManager.shared.fetchLLMUsageSummary()
      }.value
      guard !Task.isCancelled else { return }
      summary = loaded
    }
    .onReceive(NotificationCenter.default.publisher(for: .llmUsageUpdated)) { _ in
      refreshID += 1
    }
  }
}
