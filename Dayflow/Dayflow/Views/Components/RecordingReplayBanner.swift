import SwiftUI

extension Notification.Name {
  static let recordingReplayShowDate = Notification.Name("recordingReplayShowDate")
}

/// Presentation metadata only; recording import and analysis belong to RecordingReplay.
enum RecordingReplayPreview {
  static var isEnabled: Bool {
    AppStoragePaths.isUIPreview
      && RecordingReplay.isRequested
  }

  struct SourceWindow: Decodable, Identifiable {
    let label: String
    let startTs: Double
    let endTs: Double
    var id: Double { startTs }
    var start: Date { Date(timeIntervalSince1970: startTs) }
    var end: Date { Date(timeIntervalSince1970: endTs) }
  }

  private struct Manifest: Decodable {
    let windows: [SourceWindow]
  }

  static let windows: [SourceWindow] = {
    guard isEnabled,
      let url = AppStoragePaths.replayManifestURL,
      let data = try? Data(contentsOf: url),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
    else { return [] }
    return manifest.windows.filter { $0.endTs > $0.startTs }.sorted { $0.startTs < $1.startTs }
  }()

  static var initialDate: Date? { isEnabled ? windows.first?.start : nil }
}

struct RecordingReplayBanner: View {
  @ObservedObject private var replay = RecordingReplay.shared
  @State private var selectedSource: Date? = RecordingReplayPreview.initialDate
  @State private var runStartedAt: Date?
  @State private var elapsed: TimeInterval = 0
  @State private var modelName = "读取配置中"

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Label("真实录屏回放预览", systemImage: "play.rectangle")
          .font(.headline)
        Text("独立数据 · 不录制 · 不提醒")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(runDescription(at: context.date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 10) {
        Text("来源时段")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(RecordingReplayPreview.windows) { window in
          Button {
            selectedSource = window.start
            NotificationCenter.default.post(name: .recordingReplayShowDate, object: window.start)
          } label: {
            HStack(spacing: 4) {
              if selectedSource == window.start {
                Image(systemName: "checkmark.circle.fill")
              }
              Text(window.start.formatted(.dateTime.month().day()))
              Text("\(window.start.formatted(date: .omitted, time: .shortened))–\(window.end.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption.monospacedDigit())
          }
          .buttonStyle(.bordered)
          .help(window.label)
        }
        Spacer(minLength: 8)
        Text("时间线模型：\(replay.modelDescription ?? modelName)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(replay.modelDescription ?? modelName)
      }
      HStack(spacing: 10) {
        if replay.isRunning {
          ProgressView(value: Double(replay.completedBatches), total: Double(max(1, replay.totalBatches)))
            .frame(width: 120)
        }
        Text(replay.status)
          .lineLimit(2)
        Spacer(minLength: 8)
        Text("\(replay.completedBatches) / \(replay.totalBatches) 批次")
          .monospacedDigit()
        if let path = replay.reportPath {
          Button("查看报告") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          }
          .buttonStyle(.borderless)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(.regularMaterial)
    .overlay(alignment: .bottom) { Divider() }
    .onAppear {
      updateModelName()
      if replay.isRunning { runStartedAt = Date() } else { elapsed = replay.elapsedSeconds }
    }
    .onChange(of: replay.elapsedSeconds) { _, seconds in
      if !replay.isRunning { elapsed = seconds }
    }
    .onChange(of: replay.isRunning) { _, running in
      if running {
        elapsed = 0
        runStartedAt = Date()
        updateModelName()
      } else if let started = runStartedAt {
        elapsed = max(replay.elapsedSeconds, Date().timeIntervalSince(started))
        runStartedAt = nil
      }
    }
  }

  private func runDescription(at date: Date) -> String {
    if RecordingReplay.isViewOnly { return "结果预览" }
    let seconds = Int(max(0, runStartedAt.map { date.timeIntervalSince($0) } ?? elapsed))
    let duration = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    let state = replay.isRunning ? "回放中" : (RecordingReplay.isViewOnly ? "结果预览" : "已结束")
    return "\(state) · 已用时 \(duration)"
  }

  private func updateModelName() {
    guard let configuration = try? AIConfigurationStore.shared.load(),
      let assignment = configuration.routes[.timeline]?.primary ?? configuration.defaultModel
    else {
      modelName = "未配置"
      return
    }
    modelName = assignment.modelID
  }
}
