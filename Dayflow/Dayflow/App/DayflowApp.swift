//
//  DayflowApp.swift
//  Dayflow
//

import SwiftUI

struct AppRootView: View {
  @EnvironmentObject private var categoryStore: CategoryStore
  @AppStorage("didOnboard", store: AppStoragePaths.defaults) private var didOnboard = false

  var body: some View {
    Group {
      if didOnboard {
        MainView()
      } else {
        OnboardingFlow()
      }
    }
    .environmentObject(AppState.shared)
    .environmentObject(categoryStore)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: openPendingNotificationDestination)
    .onChange(of: didOnboard) { _, _ in openPendingNotificationDestination() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in openPendingNotificationDestination()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: AppDelegate.notificationNavigationRequested)
    ) {
      _ in openPendingNotificationDestination()
    }
  }

  private func openPendingNotificationDestination() {
    guard didOnboard else { return }
    // Let MainView mount its navigation subscriptions when opening a cold window.
    DispatchQueue.main.async {
      guard let destination = AppDelegate.pendingNotificationNavigationDestination else { return }
      AppDelegate.pendingNotificationNavigationDestination = nil
      switch destination {
      case .events:
        NotificationCenter.default.post(name: .navigateToEvents, object: nil)
      }
    }
  }
}

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var systemAppearance = SystemAppearanceObserver()
  @AppStorage(DayflowAppearance.storageKey, store: AppStoragePaths.defaults) private var appearance: DayflowAppearance = .system
  @StateObject private var categoryStore = CategoryStore.shared

  init() {
    // A terminal closing its stdout reader must not terminate the app.
    signal(SIGPIPE, SIG_IGN)
  }

  var body: some Scene {
    Window("Target Flow", id: "main") {
      AppRootView()
        .environmentObject(categoryStore)
        .background {
          MainWindowRegistrationView()
          DayflowWindowBackground()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .preferredColorScheme(appearance.colorScheme(system: systemAppearance.colorScheme))
        .resolveDayflowTheme()
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 558, maxHeight: .infinity)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1320, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}

// Notifications shared by the active timeline and settings.
extension Notification.Name {
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let hideTimelineFailureToast = Notification.Name("hideTimelineFailureToast")
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
}

@MainActor
final class MainWindowController {
  static let shared = MainWindowController()

  private var openWindowAction: OpenWindowAction?
  private var hasPendingOpenRequest = false

  func register(_ openWindowAction: OpenWindowAction) {
    self.openWindowAction = openWindowAction

    if hasPendingOpenRequest {
      hasPendingOpenRequest = false
      openWindowAction(id: "main")
    }
  }

  func showMainWindow() {
    guard let openWindowAction else {
      hasPendingOpenRequest = true
      return
    }

    openWindowAction(id: "main")
  }
}

/// Full-window gradient behind the main app.
private struct DayflowWindowBackground: View {
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    theme.sidebarBackground
  }
}

private struct MainWindowRegistrationView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        MainWindowController.shared.register(openWindow)
      }
  }
}
