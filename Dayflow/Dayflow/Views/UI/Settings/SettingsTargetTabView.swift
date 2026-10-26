import AppKit
import SwiftUI
@preconcurrency import UserNotifications

struct TargetNotificationSettingsView: View {
  @AppStorage(TargetPreferences.alertsEnabledKey) private var alertsEnabled = true
  @AppStorage(TargetPreferences.notificationStyleKey) private var style: TargetNotificationStyle = .notch
  @AppStorage(TargetPreferences.soundEnabledKey) private var soundEnabled = true
  @AppStorage(TargetPreferences.reminderSoundKey) private var sound: TargetReminderSound = .gemCollect
  @State private var notificationSettings: UNNotificationSettings?
  @State private var isWorking = false
  @State private var feedback: String?
  @State private var feedbackIsError = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      SettingsSection(
        title: "目标提醒",
        subtitle: "在时间线的“事件与目标”中开启当前目标。中性和分心事件会提醒，推进任意当前目标则不提醒。"
      ) {
        SettingsRow(label: "偏离提醒", subtitle: "每次新事件评估后生效，同一段记录不重复提醒。") {
          SettingsToggle(isOn: $alertsEnabled)
            .accessibilityLabel("偏离提醒")
        }
        SettingsRow(label: "提醒样式", subtitle: styleDescription, showsDivider: false) {
          Picker("提醒样式", selection: $style) {
            ForEach(TargetNotificationStyle.allCases) { style in
              Text(style.title).tag(style)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .disabled(isWorking)
        }
      }

      SettingsSection(
        title: "游戏提示音",
        subtitle: "与 Cindy 相同的游戏音效。刘海通知和系统 Notice 都使用所选声音，音量跟随系统输出音量。"
      ) {
        SettingsRow(label: "播放提示音") {
          SettingsToggle(isOn: $soundEnabled)
            .accessibilityLabel("播放提示音")
        }
        SettingsRow(label: "选择声音") {
          Picker("选择声音", selection: $sound) {
            ForEach(TargetReminderSound.allCases) { sound in
              Text(sound.title).tag(sound)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
        SettingsRow(label: "试听", subtitle: "只播放选中的声音，不显示提醒。", showsDivider: false) {
          SettingsSecondaryButton(title: "试听声音", isDisabled: !soundEnabled) {
            feedbackIsError = !NotificationService.shared.playTargetReminderSound()
            feedback = feedbackIsError ? "无法播放所选音效，请重试。" : "正在试听：\(sound.title)"
          }
        }
      }

      if style == .notch {
        SettingsSection(
          title: "刘海通知",
          subtitle: "提醒从顶部摄像头的刘海区域展开；无刘海的显示器在顶部中央显示。无需系统通知权限。"
        ) {
          SettingsRow(
            label: "展开与收回",
            subtitle: "展开 12 秒后自动收回，鼠标悬停时保持展开；移开后 5 秒收回。",
            showsDivider: false
          ) {
            Text("悬停保持展开")
              .font(.custom("Figtree", size: 12))
              .foregroundColor(SettingsStyle.secondary)
          }
        }
      } else {
        systemNoticeSettings
      }

      SettingsSection(title: "测试提醒", subtitle: "使用当前样式和声音立即测试，不受偏离提醒开关限制。") {
        SettingsRow(label: style == .notch ? "预览刘海通知" : "发送系统通知", showsDivider: false) {
          SettingsSecondaryButton(title: "测试提醒", isDisabled: isWorking) {
            sendTestNotification()
          }
        }
        if let feedback {
          Text(feedback)
            .font(.custom("Figtree", size: 12))
            .foregroundColor(feedbackIsError ? SettingsStyle.destructive : SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        }
      }
    }
    .task(id: style) {
      if style == .notice { await refreshNotificationSettings() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if style == .notice { Task { await refreshNotificationSettings() } }
    }
    .onChange(of: alertsEnabled) { _, enabled in
      if !enabled {
        NotchNotificationController.shared.dismissImmediately()
        Task { await NotificationService.shared.clearTargetNotifications() }
      }
    }
    .onChange(of: style) { _, _ in
      feedback = nil
      NotchNotificationController.shared.dismissImmediately()
      isWorking = true
      Task { @MainActor in
        defer { isWorking = false }
        await NotificationService.shared.clearTargetNotifications()
      }
    }
    .onChange(of: soundEnabled) { _, enabled in
      if !enabled { NotificationService.shared.stopTargetReminderSound() }
    }
    .onChange(of: sound) { _, _ in
      NotificationService.shared.stopTargetReminderSound()
      feedback = nil
    }
  }

  private var styleDescription: String {
    style == .notch
      ? "在屏幕顶部刘海处展开，不需要系统通知权限。"
      : "使用原先的 macOS 通知横幅；需要系统通知权限，受专注模式影响。"
  }

  private var systemNoticeSettings: some View {
    SettingsSection(title: "系统通知（Notice）", subtitle: "请在 macOS 中允许通知、横幅和声音；专注模式可能静音或隐藏通知。") {
      SettingsRow(label: "通知权限") { authorizationStatus }
      SettingsRow(label: "横幅或提醒") { settingStatus(notificationSettings?.alertSetting) }
      SettingsRow(label: "声音") { settingStatus(notificationSettings?.soundSetting) }
      SettingsRow(label: "通知授权") {
        SettingsPrimaryButton(
          title: "请求权限", isLoading: isWorking,
          isDisabled: notificationSettings?.authorizationStatus != .notDetermined
        ) {
          requestPermission()
        }
      }
      SettingsRow(label: "系统设置", showsDivider: false) {
        SettingsLinkButton(title: "打开通知设置", action: openNotificationSettings)
      }
    }
  }

  private var authorizationStatus: SettingsStatusDot {
    guard let status = notificationSettings?.authorizationStatus else {
      return SettingsStatusDot(state: .idle, label: "读取中…")
    }
    switch status {
    case .notDetermined: return SettingsStatusDot(state: .idle, label: "尚未授权")
    case .denied: return SettingsStatusDot(state: .bad, label: "已拒绝")
    case .authorized: return SettingsStatusDot(state: .good, label: "已授权")
    case .provisional: return SettingsStatusDot(state: .warn, label: "临时授权（静默通知）")
    @unknown default: return SettingsStatusDot(state: .warn, label: "未知状态")
    }
  }

  private func settingStatus(_ setting: UNNotificationSetting?) -> SettingsStatusDot {
    guard let setting else { return SettingsStatusDot(state: .idle, label: "读取中…") }
    switch setting {
    case .enabled: return SettingsStatusDot(state: .good, label: "已开启")
    case .disabled: return SettingsStatusDot(state: .warn, label: "已关闭")
    case .notSupported: return SettingsStatusDot(state: .idle, label: "不支持")
    @unknown default: return SettingsStatusDot(state: .warn, label: "未知状态")
    }
  }

  @MainActor
  private func refreshNotificationSettings() async {
    notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
  }

  private func requestPermission() {
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      let granted = await NotificationService.shared.requestPermission()
      feedbackIsError = !granted
      feedback = granted ? "已允许系统通知，可以发送测试提醒。" : "尚未获得权限，请在系统通知设置中允许 Target Flow 通知。"
      await refreshNotificationSettings()
    }
  }

  private func sendTestNotification() {
    isWorking = true
    feedback = nil
    Task { @MainActor in
      defer { isWorking = false }
      do {
        let sent = try await NotificationService.shared.sendTargetTestNotification()
        feedbackIsError = !sent
        if style == .notch {
          feedback = sent ? "刘海通知已展开，可悬停查看或点击“查看事件与目标”。" : "未找到可显示提醒的屏幕，请重试。"
        } else {
          feedback = sent
            ? "系统通知已提交。若未显示或没有声音，请检查通知设置、专注模式和系统音量。"
            : "无法发送：请先请求通知权限，或在系统通知设置中允许通知。"
          await refreshNotificationSettings()
        }
      } catch {
        feedbackIsError = true
        feedback = "测试提醒失败：\(error.localizedDescription)"
      }
    }
  }

  private func openNotificationSettings() {
    var components = URLComponents()
    components.scheme = "x-apple.systempreferences"
    components.path = "com.apple.Notifications-Settings.extension"
    components.queryItems = [URLQueryItem(name: "id", value: Bundle.main.bundleIdentifier)]
    if let url = components.url, NSWorkspace.shared.open(url) { return }
    feedbackIsError = true
    feedback = "请手动打开“系统设置 → 通知 → Target Flow”。"
  }
}
