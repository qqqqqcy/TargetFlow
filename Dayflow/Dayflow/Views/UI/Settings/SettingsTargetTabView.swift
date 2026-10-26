import AppKit
import SwiftUI
@preconcurrency import UserNotifications

struct TargetNotificationSettingsView: View {
  @AppStorage(TargetPreferences.alertsEnabledKey) private var alertsEnabled = true
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
        SettingsRow(label: "偏离提醒", subtitle: "每次新事件评估后生效，同一段记录不重复提醒。", showsDivider: false) {
          SettingsToggle(isOn: $alertsEnabled)
            .accessibilityLabel("偏离提醒")
        }
      }

      SettingsSection(
        title: "系统通知",
        subtitle: "系统通知权限与上方的提醒开关独立。专注模式和系统设置也可能影响通知显示。"
      ) {
        SettingsRow(label: "通知权限") {
          authorizationStatus
        }
        SettingsRow(label: "横幅或提醒") {
          settingStatus(notificationSettings?.alertSetting)
        }
        SettingsRow(label: "声音") {
          settingStatus(notificationSettings?.soundSetting)
        }
        SettingsRow(label: "通知授权", subtitle: "首次使用时，请允许 Target Flow 发送通知。") {
          SettingsPrimaryButton(
            title: "请求权限", isLoading: isWorking,
            isDisabled: notificationSettings?.authorizationStatus != .notDetermined
          ) {
            requestPermission()
          }
        }
        SettingsRow(label: "系统设置", subtitle: "在 macOS 中调整通知权限、提醒样式和声音。") {
          SettingsLinkButton(title: "打开通知设置") {
            openNotificationSettings()
          }
        }
        SettingsRow(
          label: "测试通知", subtitle: "立即发送一条测试通知，不受偏离提醒开关限制。",
          showsDivider: false
        ) {
          SettingsSecondaryButton(title: "发送测试通知", isDisabled: isWorking) {
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
    .task { await refreshNotificationSettings() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in Task { await refreshNotificationSettings() }
    }
  }

  private var authorizationStatus: SettingsStatusDot {
    guard let status = notificationSettings?.authorizationStatus else {
      return SettingsStatusDot(state: .idle, label: "读取中…")
    }
    switch status {
    case .notDetermined:
      return SettingsStatusDot(state: .idle, label: "尚未授权")
    case .denied:
      return SettingsStatusDot(state: .bad, label: "已拒绝")
    case .authorized:
      return SettingsStatusDot(state: .good, label: "已授权")
    case .provisional:
      return SettingsStatusDot(state: .warn, label: "临时授权（静默通知）")
    @unknown default:
      return SettingsStatusDot(state: .warn, label: "未知状态")
    }
  }

  private func settingStatus(_ setting: UNNotificationSetting?) -> SettingsStatusDot {
    guard let setting else { return SettingsStatusDot(state: .idle, label: "读取中…") }
    switch setting {
    case .enabled:
      return SettingsStatusDot(state: .good, label: "已开启")
    case .disabled:
      return SettingsStatusDot(state: .warn, label: "已关闭")
    case .notSupported:
      return SettingsStatusDot(state: .idle, label: "不支持")
    @unknown default:
      return SettingsStatusDot(state: .warn, label: "未知状态")
    }
  }

  @MainActor
  private func refreshNotificationSettings() async {
    notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
  }

  private func requestPermission() {
    isWorking = true
    feedback = nil
    Task { @MainActor in
      defer { isWorking = false }
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound, .badge])
        feedbackIsError = !granted
        feedback = granted ? "已允许通知，可以发送测试通知。" : "尚未获得通知权限，请在系统通知设置中允许 Target Flow 通知。"
      } catch {
        feedbackIsError = true
        feedback = "请求通知权限失败：\(error.localizedDescription)"
      }
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
        feedback =
          sent
          ? "测试通知已提交。若未显示或没有声音，请检查上方系统状态、通知设置及专注模式。"
          : "无法发送：尚未获得通知权限。请先请求权限，或在系统通知设置中允许通知。"
      } catch {
        feedbackIsError = true
        feedback = "测试通知发送失败：\(error.localizedDescription)"
      }
      await refreshNotificationSettings()
    }
  }

  private func openNotificationSettings() {
    var components = URLComponents()
    components.scheme = "x-apple.systempreferences"
    components.path = "com.apple.Notifications-Settings.extension"
    if let bundleIdentifier = Bundle.main.bundleIdentifier {
      components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
    }
    if let url = components.url, NSWorkspace.shared.open(url) { return }
    if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
      NSWorkspace.shared.open(fallback)
    {
      return
    }
    feedbackIsError = true
    feedback = "无法打开系统设置。请手动打开“系统设置 → 通知 → Target Flow”。"
  }
}
