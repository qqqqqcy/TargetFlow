//
//  NotificationService.swift
//  Dayflow
//
//  Current goal and onboarding notifications.
//  Handles scheduling, permission requests, and notification tap responses.
//

import AppKit
import Foundation
@preconcurrency import UserNotifications

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
      await checkPermissionStatus()
    }
  }

  private func retireExcludedNotifications() async {
    let requests = await center.pendingNotificationRequests()
    let delivered = await center.deliveredNotifications()
    let keepsTargetNotices = TargetPreferences.notificationStyle() == .notice
    let shouldRetire: (String) -> Bool = { identifier in
      !(keepsTargetNotices && identifier.hasPrefix(Self.targetNotificationPrefix))
    }
    center.removePendingNotificationRequests(
      withIdentifiers: requests.map(\.identifier).filter(shouldRetire))
    center.removeDeliveredNotifications(
      withIdentifiers: delivered.map { $0.request.identifier }.filter(shouldRetire))
  }

  /// One-time nudge after onboarding: the first real timeline cards are ready.
  /// Never prompts for permission here; the welcome tour asks up front.
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
        identifier: identifier, body: body)
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
    identifier: String, body: String
  ) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Current goal reminder")
    content.body = body
    // System notices use macOS sound preferences independently of notch game audio.
    content.sound = .default
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
    let body = String(
      localized:
        "You spent 18 minutes on news unrelated to “Prepare for interviews.” Start with one concrete step: write the context, actions, and results of a performance optimization case."
    )
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

  // MARK: - Private Methods

  private func checkPermissionStatus() async {
    let settings = await center.notificationSettings()
    await MainActor.run {
      self.permissionGranted = Self.canScheduleNotifications(for: settings.authorizationStatus)
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

  private func activateAppForNotificationTap() {
    let showDockIcon = AppStoragePaths.defaults.object(forKey: "showDockIcon") as? Bool ?? true
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
      isTarget
    else {
      completionHandler()
      return
    }

    Task { @MainActor in
      AppDelegate.pendingNotificationNavigationDestination = .events
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
    completionHandler(isTarget ? [.banner, .sound] : [])
  }
}
