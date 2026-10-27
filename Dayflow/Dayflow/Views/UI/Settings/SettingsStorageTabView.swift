import AppKit
import SwiftUI

struct SettingsStorageTabView: View {
  @ObservedObject var viewModel: StorageSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      recordingStatusSection
      recordingQualitySection
      timelineGenerationSection
      diskUsageSection
    }
    .onAppear {
      viewModel.refreshRecordingPermission()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      viewModel.refreshRecordingPermission()
    }
    .alert(isPresented: $viewModel.showLimitConfirmation) {
      guard let pending = viewModel.pendingLimit,
        StorageSettingsViewModel.storageOptions.indices.contains(pending.index)
      else {
        return Alert(title: Text("Adjust storage limit"), dismissButton: .default(Text("OK")))
      }

      let option = StorageSettingsViewModel.storageOptions[pending.index]
      let categoryName = pending.category.displayName
      return Alert(
        title: Text("Lower \(categoryName) limit?"),
        message: Text(
          "Reducing the \(categoryName) limit to \(option.label) will immediately delete the oldest \(categoryName) data to stay under the new cap."
        ),
        primaryButton: .destructive(Text("Confirm")) {
          viewModel.applyLimit(for: pending.category, index: pending.index)
        },
        secondaryButton: .cancel {
          viewModel.pendingLimit = nil
          viewModel.showLimitConfirmation = false
        }
      )
    }
  }

  // MARK: - Recording Status

  private var recordingStatusSection: some View {
    let permissionGranted = viewModel.storagePermissionGranted == true
    let recordingEnabled = AppState.shared.isRecording
    let isRecording = permissionGranted && recordingEnabled
    let recorderStatus: SettingsStatusDot.State =
      isRecording ? .good : (permissionGranted ? .idle : .bad)
    let recorderLabel =
      isRecording
      ? String(localized: "Active")
      : (permissionGranted
        ? String(localized: "Idle")
        : String(
          localized: "Permission required",
          comment: "Screen recording is blocked because permission has not been granted."))

    return SettingsSection(
      title: String(localized: "Recording status"),
      subtitle: String(localized: "Ensure Target Flow can capture your screen.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(label: String(localized: "Screen recording permission")) {
          SettingsStatusDot(
            state: permissionGranted ? .good : .bad,
            label: permissionGranted ? String(localized: "Granted") : String(localized: "Missing")
          )
        }

        SettingsRow(label: String(localized: "Recorder"), showsDivider: false) {
          SettingsStatusDot(
            state: recorderStatus,
            label: recorderLabel
          )
        }

        if !permissionGranted {
          Text("Enable Target Flow in System Settings → Privacy & Security → Screen & System Audio Recording. Return here to check the status. If access still does not work, quit Target Flow completely and reopen it.")
            .font(.system(size: 12))
            .foregroundStyle(SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }

        HStack(spacing: 14) {
          SettingsSecondaryButton(
            title: String(localized: "Open screen recording settings"),
            action: ScreenRecordingPermissionNotice.openSystemSettings
          )
          .accessibilityIdentifier("settings.openScreenRecordingSettings")

          SettingsPrimaryButton(
            title: viewModel.isRefreshingStorage
              ? String(localized: "Checking…") : String(localized: "Run status check"),
            isLoading: viewModel.isRefreshingStorage,
            action: viewModel.runStorageStatusCheck
          )

          if let last = viewModel.lastStorageCheck {
            SettingsMetadata(text: String(localized: "Last checked \(relativeDate(last))"))
          }
        }
        .padding(.top, 18)

        if viewModel.statusCheckCompleted {
          Label {
            Text(statusCheckResult)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: permissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          }
          .font(.system(size: 12))
          .foregroundStyle(permissionGranted ? SettingsStyle.secondary : SettingsStyle.destructive)
          .padding(.top, 12)
          .accessibilityIdentifier("settings.recordingStatusResult")
        }
      }
    }
  }

  private var statusCheckResult: String {
    guard viewModel.storagePermissionGranted == true else {
      return String(localized: "Check complete: screen recording permission is missing. Click Open screen recording settings to grant access.")
    }
    if AppState.shared.isRecording {
      return String(localized: "Check complete: screen recording permission is granted and recording is enabled. This check does not verify captured frames.")
    }
    return String(localized: "Check complete: screen recording permission is granted. Recording is paused; use Resume on the timeline to start.")
  }

  // MARK: - Recording quality

  private var recordingQualitySection: some View {
    SettingsSection(
      title: String(localized: "Recording quality"),
      subtitle: String(localized: "Higher resolution and more frequent captures use more disk.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: String(localized: "Resolution"),
          subtitle: String(localized: "Height each frame is scaled to")
        ) {
          settingsMenu(
            selected: ScreenshotConfig.label(forHeight: viewModel.captureHeight),
            options: ScreenshotConfig.heightOptions.map {
              ($0, ScreenshotConfig.label(forHeight: $0))
            },
            onSelect: viewModel.setCaptureHeight
          )
        }

        SettingsRow(
          label: String(localized: "Capture frequency"),
          subtitle: String(localized: "How often a frame is taken"), showsDivider: false
        ) {
          settingsMenu(
            selected: ScreenshotConfig.label(forInterval: viewModel.captureInterval),
            options: ScreenshotConfig.intervalOptions.map {
              ($0, ScreenshotConfig.label(forInterval: $0))
            },
            onSelect: viewModel.setCaptureInterval
          )
        }

        VStack(alignment: .leading, spacing: 4) {
          SettingsMetadata(text: viewModel.recordingEstimateText())
          if let observed = viewModel.observedRateText() {
            SettingsMetadata(text: observed)
          }
        }
        .padding(.top, 18)
      }
    }
  }

  private var timelineGenerationSection: some View {
    SettingsSection(
      title: String(localized: "Event timeline"),
      subtitle: String(localized: "Shorter intervals provide faster updates and more frequent AI requests.")
    ) {
      SettingsRow(
        label: String(localized: "Card generation interval"),
        subtitle: String(localized: "New recordings are analyzed at this interval. The same event may extend an existing card, so card durations vary."),
        showsDivider: false
      ) {
        settingsMenu(
          selected: AnalysisPreferences.label(for: viewModel.analysisInterval),
          options: AnalysisPreferences.intervalOptions.map {
            ($0, AnalysisPreferences.label(for: $0))
          },
          onSelect: viewModel.setAnalysisInterval
        )
      }
    }
  }

  /// Compact dropdown matching the storage-limit picker below.
  private func settingsMenu<Value: Hashable>(
    selected: String,
    options: [(value: Value, label: String)],
    onSelect: @escaping (Value) -> Void
  ) -> some View {
    Menu {
      ForEach(options, id: \.value) { option in
        Button(option.label) { onSelect(option.value) }
      }
    } label: {
      HStack(spacing: 5) {
        Text(selected)
          .font(.system(size: 13))
          .fontWeight(.semibold)
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundColor(SettingsStyle.ink)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(SettingsStyle.subtleFill)
      )
    }
    .menuStyle(BorderlessButtonMenuStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .pointingHandCursor()
  }

  // MARK: - Disk usage

  private var diskUsageSection: some View {
    SettingsSection(
      title: String(localized: "Disk usage"),
      subtitle: String(localized: "Open folders or adjust per-type storage caps.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        usageRow(
          category: .recordings,
          label: String(localized: "Recordings"),
          size: viewModel.recordingsUsageBytes,
          limitIndex: viewModel.recordingsLimitIndex,
          limitBytes: viewModel.recordingsLimitBytes,
          action: viewModel.openRecordingsFolder
        )
        usageRow(
          category: .timelapses,
          label: String(localized: "Timelapses"),
          size: viewModel.timelapseUsageBytes,
          limitIndex: viewModel.timelapsesLimitIndex,
          limitBytes: viewModel.timelapsesLimitBytes,
          action: viewModel.openTimelapseFolder,
          showsDivider: false
        )

        Text(viewModel.storageFooterText())
          .font(.system(size: 12))
          .foregroundColor(SettingsStyle.meta)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 18)
      }
    }
  }

  /// One category of storage: label + usage metadata on the left, Open +
  /// limit controls on the right, progress bar spanning full width below.
  /// Uses the single ink accent — categories differ by label, not color.
  private func usageRow(
    category: StorageCategory,
    label: String,
    size: Int64,
    limitIndex: Int,
    limitBytes: Int64,
    action: @escaping () -> Void,
    showsDivider: Bool = true
  ) -> some View {
    let usageString = viewModel.usageFormatter.string(fromByteCount: size)
    let progress: Double? =
      limitBytes == Int64.max || limitBytes == 0
      ? nil : min(Double(size) / Double(limitBytes), 1.0)
    let percentString: String? = progress.map { String(format: "%.0f%%", $0 * 100) }
    let metadata = [usageString, percentString].compactMap { $0 }.joined(separator: " · ")
    let option = StorageSettingsViewModel.storageOptions[limitIndex]

    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .font(.system(size: 14))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text(metadata)
            .font(.system(size: 12))
            .foregroundColor(SettingsStyle.secondary)
        }
        Spacer(minLength: 12)

        HStack(spacing: 8) {
          SettingsSecondaryButton(title: String(localized: "Open"), action: action)

          Menu {
            ForEach(StorageSettingsViewModel.storageOptions) { candidate in
              Button(candidate.label) {
                viewModel.handleLimitSelection(for: category, index: candidate.id)
              }
            }
          } label: {
            HStack(spacing: 5) {
              Text(option.label)
                .font(.system(size: 13))
                .fontWeight(.semibold)
              Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(SettingsStyle.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(SettingsStyle.subtleFill)
            )
          }
          .menuStyle(BorderlessButtonMenuStyle())
          .menuIndicator(.hidden)
          .fixedSize()
          .pointingHandCursor()
        }
      }
      .padding(.vertical, SettingsStyle.rowVerticalPadding)

      if let progress {
        ProgressView(value: progress)
          .progressViewStyle(LinearProgressViewStyle(tint: SettingsStyle.ink))
          .padding(.bottom, 14)
      }

      if showsDivider {
        Rectangle()
          .fill(SettingsStyle.divider)
          .frame(height: 1)
      }
    }
  }

  private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
