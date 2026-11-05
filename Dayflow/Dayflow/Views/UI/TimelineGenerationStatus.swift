import SwiftUI

/// The status pill describes actual pipeline work, not just recording being on.
enum TimelineGenerationStatus: Equatable {
  case analyzing, queued, collecting(seconds: Int), ready, stabilizing, recovering, waiting

  static func resolve(
    liveAnalyzing: Bool, liveQueued: Bool, recovering: Bool,
    deadline: Date?, pendingDuration: TimeInterval?, now: Date
  ) -> Self {
    if liveAnalyzing { return .analyzing }
    if liveQueued { return .queued }
    if let deadline {
      let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
      return seconds > 0 ? .collecting(seconds: seconds) : .ready
    }
    if pendingDuration != nil { return .stabilizing }
    if recovering { return .recovering }
    return .waiting
  }

  var title: String {
    switch self {
    case .analyzing: return String(localized: "Analyzing current recording…")
    case .queued: return String(localized: "Current recording queued")
    case .collecting: return String(localized: "Collecting recording")
    case .ready: return String(localized: "Recording ready for analysis")
    case .stabilizing: return String(localized: "Collecting a stable event window")
    case .recovering: return String(localized: "Recovering earlier recordings…")
    case .waiting: return String(localized: "Waiting for recording data")
    }
  }
}

struct NextCardGenerationStatusText: View {
  @ObservedObject private var analysisManager = AnalysisManager.shared

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let status = TimelineGenerationStatus.resolve(
        liveAnalyzing: analysisManager.liveBatchIsAnalyzing,
        liveQueued: analysisManager.liveBatchIsQueued,
        recovering: analysisManager.isRecoveringEarlierBatches,
        deadline: analysisManager.nextCardAnalysisDate,
        pendingDuration: analysisManager.latestPendingEventDuration,
        now: context.date)
      if case .collecting(let seconds) = status {
        (Text(status.title) + Text(" · ")
          + Text("\(seconds / 60) min \(seconds % 60) sec remaining"))
          .monospacedDigit()
      } else {
        Text(status.title)
      }
    }
    .help("Short switches are absorbed into the dominant event. Recording gaps stay separate.")
  }
}
