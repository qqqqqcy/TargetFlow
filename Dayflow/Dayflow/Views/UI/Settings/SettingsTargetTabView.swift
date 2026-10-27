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
        title: String(localized: "Goal reminders"),
        subtitle: String(localized: "Enable current goals in Events & Goals on the timeline. Neutral and distracted events trigger reminders; progress toward any current goal does not.")
      ) {
        SettingsRow(label: String(localized: "Deviation reminders"), subtitle: String(localized: "Applies after each new event assessment. The same recording will not trigger repeated reminders.")) {
          SettingsToggle(isOn: $alertsEnabled)
            .accessibilityLabel(String(localized: "Deviation reminders"))
        }
        SettingsRow(label: String(localized: "Reminder style"), subtitle: styleDescription, showsDivider: false) {
          Picker(String(localized: "Reminder style"), selection: $style) {
            ForEach(TargetNotificationStyle.allCases) { style in
              Text(style.title).tag(style)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .disabled(isWorking)
        }
      }

      if style == .notch {
        SettingsSection(
          title: String(localized: "Game sounds"),
          subtitle: String(localized: "Used only for notch notifications. Volume follows the system output volume.")
        ) {
          SettingsRow(label: String(localized: "Play reminder sound")) {
            SettingsToggle(isOn: $soundEnabled)
              .accessibilityLabel(String(localized: "Play reminder sound"))
          }
          SettingsRow(label: String(localized: "Choose sound")) {
            Picker(String(localized: "Choose sound"), selection: $sound) {
              ForEach(TargetReminderSound.allCases) { sound in
                Text(sound.title).tag(sound)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
          }
          SettingsRow(label: String(localized: "Preview"), subtitle: String(localized: "Play the selected sound without showing a reminder."), showsDivider: false) {
            SettingsSecondaryButton(title: String(localized: "Preview sound"), isDisabled: !soundEnabled) {
              feedbackIsError = !NotificationService.shared.playTargetReminderSound()
              feedback = feedbackIsError ? String(localized: "Unable to play the selected sound. Please try again.") : String(localized: "Previewing: \(sound.title)")
            }
          }
        }
      }

      if style == .notch {
        SettingsSection(
          title: String(localized: "Notch notifications"),
          subtitle: String(localized: "Reminders expand from the camera notch at the top of the screen, or from the top center on displays without a notch. System notification permission is not required.")
        ) {
          SettingsRow(
            label: String(localized: "Expand & collapse"),
            subtitle: String(localized: "Collapses automatically after 12 seconds. Hover to keep it expanded; it collapses 5 seconds after the pointer leaves."),
            showsDivider: false
          ) {
            Text(String(localized: "Hover to keep expanded"))
              .font(.system(size: 12))
              .foregroundColor(SettingsStyle.secondary)
          }
        }
      } else {
        systemNoticeSettings
      }

      SettingsSection(title: String(localized: "Test reminder"), subtitle: String(localized: "Test immediately using the current style and sound, even when deviation reminders are off.")) {
        SettingsRow(label: style == .notch ? String(localized: "Preview notch notification") : String(localized: "Send system notification"), showsDivider: false) {
          SettingsSecondaryButton(title: String(localized: "Test reminder"), isDisabled: isWorking) {
            sendTestNotification()
          }
        }
        if let feedback {
          Text(feedback)
            .font(.system(size: 12))
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
      ? String(localized: "Expands from the notch at the top of the screen. System notification permission is not required.")
      : String(localized: "Uses macOS notification banners and the default system sound. Notification permissions and Focus mode apply.")
  }

  private var systemNoticeSettings: some View {
    SettingsSection(title: String(localized: "System notifications (Notice)"), subtitle: String(localized: "Allow notifications, banners, and sounds in macOS. Focus mode may silence or hide notifications.")) {
      SettingsRow(label: String(localized: "Notification permission")) { authorizationStatus }
      SettingsRow(label: String(localized: "Banners or alerts")) { settingStatus(notificationSettings?.alertSetting) }
      SettingsRow(label: String(localized: "Sound")) { settingStatus(notificationSettings?.soundSetting) }
      SettingsRow(label: String(localized: "Notification authorization")) {
        SettingsPrimaryButton(
          title: String(localized: "Request permission"), isLoading: isWorking,
          isDisabled: notificationSettings?.authorizationStatus != .notDetermined
        ) {
          requestPermission()
        }
      }
      SettingsRow(label: String(localized: "System Settings"), showsDivider: false) {
        SettingsLinkButton(title: String(localized: "Open notification settings"), action: openNotificationSettings)
      }
    }
  }

  private var authorizationStatus: SettingsStatusDot {
    guard let status = notificationSettings?.authorizationStatus else {
      return SettingsStatusDot(state: .idle, label: String(localized: "Loading…"))
    }
    switch status {
    case .notDetermined: return SettingsStatusDot(state: .idle, label: String(localized: "Not authorized yet"))
    case .denied: return SettingsStatusDot(state: .bad, label: String(localized: "Denied"))
    case .authorized: return SettingsStatusDot(state: .good, label: String(localized: "Authorized"))
    case .provisional: return SettingsStatusDot(state: .warn, label: String(localized: "Provisional authorization (quiet notifications)"))
    @unknown default: return SettingsStatusDot(state: .warn, label: String(localized: "Unknown status"))
    }
  }

  private func settingStatus(_ setting: UNNotificationSetting?) -> SettingsStatusDot {
    guard let setting else { return SettingsStatusDot(state: .idle, label: String(localized: "Loading…")) }
    switch setting {
    case .enabled: return SettingsStatusDot(state: .good, label: String(localized: "Enabled"))
    case .disabled: return SettingsStatusDot(state: .warn, label: String(localized: "Disabled"))
    case .notSupported: return SettingsStatusDot(state: .idle, label: String(localized: "Not supported"))
    @unknown default: return SettingsStatusDot(state: .warn, label: String(localized: "Unknown status"))
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
      feedback = granted ? String(localized: "System notifications are allowed. You can send a test reminder.") : String(localized: "Permission has not been granted. Allow Target Flow notifications in system notification settings.")
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
          feedback = sent ? String(localized: "The notch notification is expanded. Hover to view it or click “View Events & Goals”.") : String(localized: "No screen is available to show the reminder. Please try again.")
        } else {
          feedback = sent
            ? String(localized: "The system notification was submitted. If it does not appear or play a sound, check notification settings, Focus mode, and system volume.")
            : String(localized: "Unable to send: request notification permission first, or allow notifications in system notification settings.")
          await refreshNotificationSettings()
        }
      } catch {
        feedbackIsError = true
        feedback = String(localized: "Test reminder failed: \(error.localizedDescription)")
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
    feedback = String(localized: "Please open System Settings → Notifications → Target Flow manually.")
  }
}
