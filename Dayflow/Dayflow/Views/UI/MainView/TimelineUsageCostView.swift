import SwiftUI

extension Notification.Name {
  static let llmUsageUpdated = Notification.Name("llmUsageUpdated")
}

struct TimelineUsageCostView: View {
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
      Text(summary?.detailText ?? "暂时无法读取累计费用")
        .font(.system(size: 12))
        .textSelection(.enabled)
        .frame(width: 310, alignment: .leading)
        .padding(16)
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
