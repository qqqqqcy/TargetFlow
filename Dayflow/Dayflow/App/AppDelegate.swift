//
//  AppDelegate.swift
//  Dayflow
//

import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  enum PendingNotificationNavigationDestination: Equatable {
    case timeline
    case events
  }

  static let notificationNavigationRequested = Notification.Name("notificationNavigationRequested")
  static var pendingNotificationNavigationDestination: PendingNotificationNavigationDestination? {
    didSet {
      if pendingNotificationNavigationDestination != nil {
        NotificationCenter.default.post(name: notificationNavigationRequested, object: nil)
      }
    }
  }

  // Closing or soft-quitting keeps recording available from the menu bar.
  static var allowTermination = false

  static func permitTermination(reason: String) {
    allowTermination = true
  }

  private var statusBar: StatusBarController!
  private var recorder: ScreenRecorder!
  private var powerObserver: NSObjectProtocol?
  private var deepLinkRouter: AppDeepLinkRouter?
  private var pendingDeepLinkURLs: [URL] = []

  override init() {
    // Install before SwiftUI creates any text layers.
    FlippedTextLayerWorkaround.install()
    super.init()
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    Self.allowTermination = false
    applySavedDockIconPreference()
    statusBar = StatusBarController()

    // Create the recorder before restoring the preference so it sees the transition.
    AppState.shared.isRecording = false
    recorder = ScreenRecorder(autoStart: true)
    AppState.shared.enablePersistence()

    if UserDefaults.standard.bool(forKey: "didOnboard") {
      if ScreenRecordingPermissionNotice.isGranted {
        AppState.shared.setRecording(AppState.shared.getSavedPreference() ?? true)
      } else {
        AppState.shared.setRecording(false, persistPreference: false)
        ScreenRecordingPermissionNotice.post(reason: "launch_preflight_missing")
      }
    }
    NotificationService.shared.start()
    TargetStore.shared.synchronize(events: CategoryStore.shared.categories)
    TargetStore.shared.retryPendingEvaluations()

    deepLinkRouter = AppDeepLinkRouter()
    flushPendingDeepLinks()
    setupTimelineAnalysis()
    InactivityMonitor.shared.start()

    powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        AppDelegate.permitTermination(reason: "power_off_or_logout")
      }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if Self.allowTermination {
      return .terminateNow
    }
    NSApp.hide(nil)
    NSApp.setActivationPolicy(.accessory)
    return .terminateCancel
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    applySavedDockIconPreference()
    sender.unhide(nil)
    MainWindowController.shared.showMainWindow()
    sender.activate(ignoringOtherApps: true)
    return false
  }

  private func applySavedDockIconPreference() {
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
  }

  private func setupTimelineAnalysis() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      AnalysisManager.shared.startAnalysisJob()
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let deepLinkRouter else {
      pendingDeepLinkURLs.append(contentsOf: urls)
      return
    }

    for url in urls {
      deepLinkRouter.handle(url)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    StorageManager.shared.checkpoint(mode: .truncate)
    InactivityMonitor.shared.stop()
    if let observer = powerObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      powerObserver = nil
    }
  }

  private func flushPendingDeepLinks() {
    guard let router = deepLinkRouter, !pendingDeepLinkURLs.isEmpty else { return }
    let urls = pendingDeepLinkURLs
    pendingDeepLinkURLs.removeAll()
    for url in urls {
      router.handle(url)
    }
  }
}
