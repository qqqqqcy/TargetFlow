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
      Text("· " + (summary?.costText ?? String(localized: "Total cost —")))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .help(summary?.detailText ?? String(localized: "Total cost is currently unavailable"))
    .popover(isPresented: $showsDetails, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 12) {
        Label(String(localized: "API usage & cost"), systemImage: "chart.bar.doc.horizontal")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(theme.textPrimary)
        Rectangle().fill(theme.rightPanelDivider).frame(height: 1)
        Text(summary?.detailText ?? String(localized: "Total cost is currently unavailable"))
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
