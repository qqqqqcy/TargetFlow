//
//  NotificationService.swift
//  Dayflow
//
//  Main orchestrator for Daily and Weekly notifications.
//  Handles scheduling, permission requests, and notification tap responses.
//

import AppKit
import Foundation
@preconcurrency import UserNotifications

enum WeeklyUnlockNotificationScheduleResult {
  case scheduled
  case denied
  case failed
}

@MainActor
final class NotificationService: NSObject, ObservableObject {
  static let shared = NotificationService()

  private let center = UNUserNotificationCenter.current()
  private var targetSound: NSSound?
  nonisolated private static let targetNotificationPrefix = "target.deviation."

  @Published private(set) var permissionGranted: Bool = false

  override private init() {
    super.init()
  }

  // MARK: - Public Methods

  /// Call this from AppDelegate.applicationDidFinishLaunching
  func start() {
    center.delegate = self

    // Check current permission status
    Task {
      await retireExcludedNotifications()
      await retireJournalNotifications()
      await checkPermissionStatus()
    }
  }

  private func retireExcludedNotifications() async {
    let requests = await center.pendingNotificationRequests()
    let delivered = await center.deliveredNotifications()
    let keepsTargetNotices = TargetPreferences.notificationStyle() == .notice
    let shouldRetire: (String) -> Bool = { identifier in
      identifier != "gettingStarted.firstCards"
        && !(keepsTargetNotices && identifier.hasPrefix(Self.targetNotificationPrefix))
    }
    center.removePendingNotificationRequests(
      withIdentifiers: requests.map(\.identifier).filter(shouldRetire))
    center.removeDeliveredNotifications(
      withIdentifiers: delivered.map { $0.request.identifier }.filter(shouldRetire))
  }

  func clearSupportReplyNotification() {
    center.removeDeliveredNotifications(withIdentifiers: ["support.reply"])
    center.removePendingNotificationRequests(withIdentifiers: ["support.reply"])
  }

  func notifySupportReply() {
    notifyChatReply()
  }

  func clearFlowWaitlistReplyNotification() {
    center.removeDeliveredNotifications(withIdentifiers: ["flow.waitlist.reply"])
    center.removePendingNotificationRequests(withIdentifiers: ["flow.waitlist.reply"])
  }

  func notifyFlowWaitlistReply(sessionKey: String) {
    notifyChatReply(flowSessionKey: sessionKey)
  }

  private func notifyChatReply(flowSessionKey: String? = nil) {
    Task {
      var status = await authorizationStatus()
      if status == .notDetermined {
        await requestPermission()
        status = await authorizationStatus()
      }
      guard Self.canScheduleNotifications(for: status) else { return }
      let badges = NotificationBadgeManager.shared
      if let flowSessionKey {
        guard badges.flowWaitlistSessionKey == flowSessionKey, badges.flowWaitlistUnreadCount > 0
        else { return }
      } else {
        guard badges.supportUnreadCount > 0 else { return }
      }
      let isFlow = flowSessionKey != nil
      let identifier = isFlow ? "flow.waitlist.reply" : "support.reply"
      let content = UNMutableNotificationContent()
      content.title = String(localized: "New reply from Target Flow")
      content.body =
        isFlow
        ? String(localized: "You have a new reply about Flow. Open Flow to read it.")
        : String(localized: "You have a new support reply. Open Support to read it.")
      content.sound = .default
      do {
        try await center.add(
          UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
      } catch {
        print("[NotificationService] Chat notification failed (\(identifier)): \(error)")
      }
    }
  }

  /// One-time nudge after onboarding: the first real timeline cards are ready.
  /// Never prompts for permission here; the welcome tour asks up front.
  func notifyFirstCardsReady() {
    Task {
      let status = await authorizationStatus()
      guard Self.canScheduleNotifications(for: status) else { return }

      let content = UNMutableNotificationContent()
      content.title = String(localized: "Your first Target Flow cards are ready")
      content.body = String(
        localized: "Take a look at what Target Flow picked up from your last few minutes of work.")
      content.sound = .default
      do {
        try await center.add(
          UNNotificationRequest(
            identifier: "gettingStarted.firstCards", content: content, trigger: nil))
        AnalyticsService.shared.capture("getting_started_first_cards_notification_sent")
      } catch {
        print("[NotificationService] First cards notification failed: \(error)")
      }
    }
  }

  /// System notices require authorization; notch reminders play their own short sound.
  func notifyTargetDeviation(
    identifier: String, body: String, shouldSend: () -> Bool = { true }
  ) async throws -> Bool {
    guard shouldSend() else { return false }
    switch TargetPreferences.notificationStyle() {
    case .notch:
      guard NotchNotificationController.shared.show(body: body) else { return false }
      playTargetReminderSound()
      return true
    case .notice:
      let status = await authorizationStatus()
      // Preferences or the active goal may have changed during the permission lookup.
      guard Self.canScheduleNotifications(for: status),
        TargetPreferences.notificationStyle() == .notice, shouldSend()
      else { return false }
      let request = Self.targetNoticeRequest(
        identifier: identifier, body: body, soundEnabled: TargetPreferences.soundEnabled(),
        sound: TargetPreferences.reminderSound())
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        center.add(request) { error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume() }
        }
      }
      return true
    }
  }

  static func targetNoticeRequest(
    identifier: String, body: String, soundEnabled: Bool, sound: TargetReminderSound
  ) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "当前目标提醒"
    content.body = body
    content.sound = soundEnabled ? UNNotificationSound(named: .init(sound.filename)) : nil
    return UNNotificationRequest(
      identifier: targetNotificationPrefix + identifier, content: content, trigger: nil)
  }

  @discardableResult
  func playTargetReminderSound() -> Bool {
    guard TargetPreferences.soundEnabled(), let url = TargetPreferences.reminderSound().url else {
      return false
    }
    targetSound?.stop()
    targetSound = NSSound(contentsOf: url, byReference: true)
    return targetSound?.play() ?? false
  }

  func stopTargetReminderSound() {
    targetSound?.stop()
  }

  /// Remove old notices when changing delivery style so the two modes do not overlap.
  func clearTargetNotifications() async {
    stopTargetReminderSound()
    let pending = await center.pendingNotificationRequests()
    let delivered = await center.deliveredNotifications()
    center.removePendingNotificationRequests(
      withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.targetNotificationPrefix) })
    center.removeDeliveredNotifications(
      withIdentifiers: delivered.map { $0.request.identifier }
        .filter { $0.hasPrefix(Self.targetNotificationPrefix) })
  }

  func sendTargetTestNotification() async throws -> Bool {
    let body = TargetPreferences.notificationStyle() == .notch
      ? "这是一条刘海测试提醒。先选一个当前目标，从一个具体的小步骤继续。悬停可保持展开，点击下方按钮查看事件与目标。"
      : "这是一条目标测试通知。先选一个当前目标，从一个具体的小步骤继续。点击可打开事件与目标。"
    return try await notifyTargetDeviation(
      identifier: "test.\(UUID().uuidString)", body: body)
  }

  /// Request notification permission from the user
  @discardableResult
  func requestPermission() async -> Bool {
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
      await MainActor.run {
        self.permissionGranted = granted
      }
      print("[NotificationService] requestPermission granted=\(granted)")
      return granted
    } catch {
      print("[NotificationService] Permission request failed: \(error)")
      return false
    }
  }

  /// Read the current notification authorization status and refresh the cached flag.
  func authorizationStatus() async -> UNAuthorizationStatus {
    let settings = await center.notificationSettings()
    let authorizationStatus = settings.authorizationStatus
    permissionGranted = Self.canScheduleNotifications(for: authorizationStatus)
    return authorizationStatus
  }

  /// Remove reminders left by the retired Journal feature without touching Daily or Weekly.
  private func retireJournalNotifications() async {
    let pending = await center.pendingNotificationRequests()
    let pendingIDs = pending.filter { $0.identifier.hasPrefix("journal.") }.map(\.identifier)
    center.removePendingNotificationRequests(withIdentifiers: pendingIDs)

    let delivered = await center.deliveredNotifications()
    let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix("journal.") }
    center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
  }

  /// Notify the user that yesterday's daily recap is ready.
  /// Called only after successful generation + DB save.
  func scheduleDailyRecapReadyNotification(forDay day: String) {
    let trimmedDay = day.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDay.isEmpty else {
      print("[NotificationService] Skipping daily recap notification: empty day")
      return
    }
    print("[NotificationService] scheduleDailyRecapReadyNotification requested day=\(trimmedDay)")

    Task {
      var settings = await center.notificationSettings()
      var status = settings.authorizationStatus
      print(
        "[NotificationService] daily recap notification settings day=\(trimmedDay) "
          + "authorization_status=\(Self.authorizationStatusName(status))"
      )

      if status == .notDetermined {
        let granted = await requestPermission()
        settings = await center.notificationSettings()
        status = settings.authorizationStatus
        print(
          "[NotificationService] daily recap permission prompt result day=\(trimmedDay) "
            + "granted=\(granted) final_status=\(Self.authorizationStatusName(status))"
        )

        AnalyticsService.shared.capture(
          "daily_auto_generation_notification_permission_prompt_result",
          [
            "target_day": trimmedDay,
            "granted": granted,
            "authorization_status": Self.authorizationStatusName(status),
          ])
      }

      guard Self.canScheduleNotifications(for: status) else {
        print(
          "[NotificationService] Skipping daily recap notification (\(trimmedDay)): "
            + "permission_status=\(Self.authorizationStatusName(status))"
        )
        AnalyticsService.shared.capture(
          "daily_auto_generation_notification_skipped",
          [
            "target_day": trimmedDay,
            "reason": "permission_not_authorized",
            "authorization_status": Self.authorizationStatusName(status),
          ])
        return
      }

      enqueueDailyRecapReadyNotification(forDay: trimmedDay, settings: settings)
    }
  }

  func scheduleWeeklyUnlockNotification(at unlockDate: Date) async
    -> WeeklyUnlockNotificationScheduleResult
  {
    var settings = await center.notificationSettings()
    var status = settings.authorizationStatus

    if status == .notDetermined {
      _ = await requestPermission()
      settings = await center.notificationSettings()
      status = settings.authorizationStatus
    }

    guard Self.canScheduleNotifications(for: status) else {
      print(
        "[NotificationService] Skipping weekly unlock notification: "
          + "permission_status=\(Self.authorizationStatusName(status))"
      )
      return .denied
    }

    return await enqueueWeeklyUnlockNotification(at: unlockDate, settings: settings)
  }

  func cancelWeeklyUnlockNotification() {
    center.removePendingNotificationRequests(withIdentifiers: ["weekly.unlock"])
  }

  // MARK: - Private Methods

  private func checkPermissionStatus() async {
    let settings = await center.notificationSettings()
    await MainActor.run {
      self.permissionGranted = Self.canScheduleNotifications(for: settings.authorizationStatus)
    }
  }

  private func enqueueDailyRecapReadyNotification(
    forDay day: String, settings: UNNotificationSettings
  ) {
    let identifier = "daily.recap.\(day)"
    print(
      "[NotificationService] enqueue daily recap identifier=\(identifier) "
        + "day=\(day) alert_setting=\(Self.notificationSettingName(settings.alertSetting)) "
        + "sound_setting=\(Self.notificationSettingName(settings.soundSetting))"
    )
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    print("[NotificationService] removed pending notification identifier=\(identifier)")

    let content = UNMutableNotificationContent()
    content.title = String(localized: "Your daily recap for yesterday is ready")
    content.body = String(localized: "Tap to open it in Daily view.")
    content.sound = .default
    content.categoryIdentifier = "daily_recap"
    content.userInfo = ["day": day]

    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    )

    let authStatus = Self.authorizationStatusName(settings.authorizationStatus)
    let alertSetting = Self.notificationSettingName(settings.alertSetting)
    let soundSetting = Self.notificationSettingName(settings.soundSetting)
    center.add(request) { error in
      if let error {
        print(
          "[NotificationService] Failed to schedule daily recap notification (\(day)): \(error)")
        AnalyticsService.shared.capture(
          "daily_auto_generation_notification_failed",
          [
            "target_day": day,
            "error_message": String(error.localizedDescription.prefix(500)),
            "authorization_status": authStatus,
            "alert_setting": alertSetting,
            "sound_setting": soundSetting,
          ])
        return
      }
      print(
        "[NotificationService] Scheduled daily recap notification "
          + "identifier=\(identifier) day=\(day)"
      )

      Task { @MainActor in
        NotificationBadgeManager.shared.registerDailyRecapReady(forDay: day)
      }

      AnalyticsService.shared.capture(
        "daily_auto_generation_notification_scheduled",
        [
          "target_day": day,
          "authorization_status": authStatus,
          "alert_setting": alertSetting,
          "sound_setting": soundSetting,
        ])
    }
  }

  private func enqueueWeeklyUnlockNotification(
    at unlockDate: Date,
    settings: UNNotificationSettings
  ) async -> WeeklyUnlockNotificationScheduleResult {
    let identifier = "weekly.unlock"
    let interval = max(1, unlockDate.timeIntervalSinceNow)

    center.removePendingNotificationRequests(withIdentifiers: [identifier])

    let content = UNMutableNotificationContent()
    content.title = String(localized: "Weekly view is ready")
    content.body = String(localized: "Tap to open your weekly review.")
    content.sound = .default
    content.categoryIdentifier = "weekly_unlock"

    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    )

    return await withCheckedContinuation { continuation in
      center.add(request) { error in
        if let error {
          print("[NotificationService] Failed to schedule weekly unlock notification: \(error)")
          continuation.resume(returning: .failed)
          return
        }

        print(
          "[NotificationService] Scheduled weekly unlock notification "
            + "identifier=\(identifier) seconds=\(Int(interval.rounded())) "
            + "alert_setting=\(Self.notificationSettingName(settings.alertSetting)) "
            + "sound_setting=\(Self.notificationSettingName(settings.soundSetting))"
        )
        continuation.resume(returning: .scheduled)
      }
    }
  }

  private static func authorizationStatusName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "not_determined"
    case .denied:
      return "denied"
    case .authorized:
      return "authorized"
    case .provisional:
      return "provisional"
    @unknown default:
      return "unknown"
    }
  }

  private static func canScheduleNotifications(for status: UNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .provisional:
      return true
    default:
      return false
    }
  }

  private static func notificationSettingName(_ setting: UNNotificationSetting) -> String {
    switch setting {
    case .notSupported:
      return "not_supported"
    case .disabled:
      return "disabled"
    case .enabled:
      return "enabled"
    @unknown default:
      return "unknown"
    }
  }

  private func activateAppForNotificationTap() {
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if showDockIcon && NSApp.activationPolicy() == .accessory {
      NSApp.setActivationPolicy(.regular)
    }

    NSApp.unhide(nil)
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
  /// Called when user taps on a notification
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    let isTarget = identifier.hasPrefix(Self.targetNotificationPrefix)
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      isTarget || identifier == "gettingStarted.firstCards"
    else {
      completionHandler()
      return
    }

    Task { @MainActor in
      AppDelegate.pendingNotificationNavigationDestination = isTarget ? .events : .timeline
      activateAppForNotificationTap()
      completionHandler()
    }
  }

  /// Called when notification fires while app is in foreground
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let isTarget = notification.request.identifier.hasPrefix(Self.targetNotificationPrefix)
    let sound: UNNotificationPresentationOptions = TargetPreferences.soundEnabled() ? [.sound] : []
    completionHandler(isTarget ? sound.union([.banner]) : [])
  }
}
