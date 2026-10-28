//
//  MainView.swift
//  Dayflow
//
//  Timeline UI with transparent design
//

import AVFoundation
import AVKit
import AppKit
import Foundation
import SwiftUI

struct MainView: View {
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var categoryStore: CategoryStore
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.dayflowTheme) var theme
  @State var selectedIcon: SidebarIcon = .timeline
  @State var selectedDate = timelineDisplayDate(from: Date())
  @State var cachedTimelineWeekRange: TimelineWeekRange = TimelineWeekRange.containing(
    timelineDisplayDate(from: Date()))
  @State var timelineMode: TimelineMode = .day
  @State var hideWeekCardsDuringModeSwitch = false
  @State var showDatePicker = false
  // Arrowless calendar card anchored to the timeline header's calendar pill
  // (distinct from `showDatePicker`, which drives a modal sheet used only by
  // the daily-view date pill).
  @State var showTimelineCalendarPopover = false
  @State var timelineCalendarButtonFrame: CGRect = .zero
  @State var selectedActivity: TimelineActivity? = nil
  @State var weekInspectorContentVisible = false
  @State var scrollToNowTick: Int = 0
  @State var hasAnyActivities: Bool = true
  @State var refreshActivitiesTrigger: Int = 0
  @ObservedObject var inactivity = InactivityMonitor.shared
  @ObservedObject var pauseManager = PauseManager.shared

  // Animation states for orchestrated entrance - Emil Kowalski principles
  @State var timelineOffset: CGFloat = -20
  @State var timelineOpacity: Double = 0
  @State var sidebarOpacity: Double = 0
  @State var contentOpacity: Double = 0

  @Namespace var timelineModeSwitchNamespace

  // Track if we've performed the initial scroll to current time
  @State var didInitialScroll = false
  @State var previousDate = timelineDisplayDate(from: Date())
  @State var lastDateNavMethod: String? = nil
  // Minute tick to handle timeline-day rollover (4am boundary): header updates + jump to today
  @State var dayChangeTimer: Timer? = nil
  @State var lastObservedTimelineDay: String = cachedDayStringFormatter.string(
    from: timelineDisplayDate(from: Date()))
  @State var showCategoryEditor = false
  // Categories the user turned off in the chip row (keys from categoryFilterKey).
  // Session-only on purpose: their cards are dimmed, not hidden.
  @State var mutedCategoryKeys: Set<String> = []
  @State var copyTimelineState: TimelineCopyState = .idle
  @State var copyTimelineTask: Task<Void, Never>? = nil
  @State var deleteTimelineTask: Task<Void, Never>? = nil
  @State var weeklyTrackedMinutes: Double = 0
  @StateObject var retryCoordinator = RetryCoordinator()
  @State var timelineFailureToastPayload: TimelineFailureToastPayload?
  @State var showScreenRecordingPermissionNotice = false
  @State var didDismissScreenRecordingPermissionNoticeThisSession = false
  /// macOS says access is granted, but the recorder gave up after captures kept failing.
  @State var screenCaptureIsFailing = false
  let rateSummaryFooterHeight: CGFloat = 28

  var body: some View {
    mainLayout
      .onReceive(NotificationCenter.default.publisher(for: .navigateToEvents)) { _ in
        selectedIcon = .timeline
        showCategoryEditor = true
      }
  }
}
