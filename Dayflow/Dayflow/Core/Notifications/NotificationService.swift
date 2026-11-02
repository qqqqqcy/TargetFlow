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

  private let automaticReminders: AutomaticReminderState
  private let delivery: Delivery

  /// Only the delivery boundary is injected; production eligibility is shared with tests.
  @MainActor
  struct Delivery {
    var authorization: @MainActor () async -> UNAuthorizationStatus
    var add: @MainActor (UNNotificationRequest) async throws -> Void
    var notificationIdentifiers: @MainActor () async -> [String]
    var remove: @MainActor ([String]) -> Void
    var showNotch: @MainActor (String) -> Bool
    var dismissNotch: @MainActor () -> Void
    var playSound: @MainActor () -> Void
    var stopSound: @MainActor () -> Void
    var style: @MainActor () -> TargetNotificationStyle

    static var live: Delivery {
      let center = UNUserNotificationCenter.current()
      return Delivery(
        authorization: { await NotificationService.shared.authorizationStatus() },
        add: { try await center.add($0) },
        notificationIdentifiers: {
          let pending = await center.pendingNotificationRequests().map(\.identifier)
          let delivered = await center.deliveredNotifications().map { $0.request.identifier }
          return pending + delivered
        },
        remove: {
          center.removePendingNotificationRequests(withIdentifiers: $0)
          center.removeDeliveredNotifications(withIdentifiers: $0)
        },
        showNotch: { NotchNotificationController.shared.show(body: $0) },
        dismissNotch: { NotchNotificationController.shared.dismissImmediately() },
        playSound: { NotificationService.shared.playTargetReminderSound() },
        stopSound: { NotificationService.shared.stopTargetReminderSound() },
        style: { TargetPreferences.notificationStyle() })
    }
  }

  init(automaticReminders: AutomaticReminderState? = nil, delivery: Delivery? = nil) {
    self.automaticReminders = automaticReminders ?? .shared
    self.delivery = delivery ?? .live
    super.init()
  }

  // MARK: - Public Methods

  /// Call this from AppDelegate.applicationDidFinishLaunching
  func start() {
    center.delegate = self

    // Check current permission status
    Task {
      await retireExcludedNotifications()
      await removeInvalidAutomaticNotices()
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

  /// Automatic goal reminders require current recording eligibility throughout delivery.
  /// Explicit settings previews opt out of that gate and never request permission here.
  func notifyTargetDeviation(
    identifier: String, body: String, shouldSend: @escaping () -> Bool = { true },
    isExplicitPreview: Bool = false
  ) async throws -> Bool {
    let generation = automaticReminders.generation
    let eligible = {
      shouldSend() && (isExplicitPreview || self.automaticReminders.allows(generation))
    }
    guard eligible() else { return false }
    switch delivery.style() {
    case .notch:
      guard delivery.showNotch(body) else { return false }
      delivery.playSound()
      return true
    case .notice:
      let status = await delivery.authorization()
      guard Self.canScheduleNotifications(for: status),
        delivery.style() == .notice, eligible()
      else { return false }
      let scopedIdentifier = isExplicitPreview
        ? "test.\(identifier)" : "auto.\(generation.uuidString).\(identifier)"
      let request = Self.targetNoticeRequest(identifier: scopedIdentifier, body: body)
      do {
        try await delivery.add(request)
      } catch {
        if !eligible() { delivery.remove([request.identifier]); return false }
        throw error
      }
      guard eligible() else {
        delivery.remove([request.identifier])
        return false
      }
      return true
    }
  }

  /// Called synchronously at the recording transition, before any suspended sender can resume.
  func pauseAutomaticReminders() {
    delivery.dismissNotch()
    delivery.stopSound()
    Task { await removeInvalidAutomaticNotices() }
  }

  func removeInvalidAutomaticNotices() async {
    let identifiers = await delivery.notificationIdentifiers()
    // Evaluate after the await: a quick resume must preserve only the new generation.
    delivery.remove(identifiers.filter {
      $0.hasPrefix(Self.targetNotificationPrefix)
        && !$0.hasPrefix(Self.targetNotificationPrefix + "test.")
        && !canPresentTargetNotice(identifier: $0)
    })
  }

  func canPresentTargetNotice(identifier: String) -> Bool {
    guard identifier.hasPrefix(Self.targetNotificationPrefix) else { return false }
    if identifier.hasPrefix(Self.targetNotificationPrefix + "test.") { return true }
    let prefix = Self.targetNotificationPrefix + "auto."
    guard identifier.hasPrefix(prefix),
      let token = identifier.dropFirst(prefix.count).split(separator: ".").first,
      let generation = UUID(uuidString: String(token))
    else { return false }
    return automaticReminders.allows(generation)
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
      identifier: UUID().uuidString, body: body, isExplicitPreview: true)
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
    let identifier = notification.request.identifier
    Task { @MainActor in
      completionHandler(canPresentTargetNotice(identifier: identifier) ? [.banner, .sound] : [])
    }
  }
}
