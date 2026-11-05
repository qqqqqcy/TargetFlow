import AppKit
import Foundation
import SwiftUI

// MARK: - Cached DateFormatter (creating DateFormatters is expensive due to ICU initialization)

private let cachedTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.timeStyle = .short
  return formatter
}()

private struct CanvasConfig {
  static let timeColumnWidth: CGFloat = 60
  static let startHour: Int = 4  // 4 AM baseline
  static let endHour: Int = 28  // 4 AM next day
}

// Positioned activity for Canvas rendering
private struct CanvasPositionedActivity: Identifiable {
  let id: String
  let activity: TimelineActivity
  // Time coordinates let async loads use the current density without DB reads on zoom.
  let startMinutes: Double
  let durationMinutes: Double
  let title: String
  let timeLabel: String
  let categoryName: String
  // Raw values for pattern matching (may contain paths like "developer.apple.com/xcode")
  let faviconPrimaryRaw: String?
  let faviconSecondaryRaw: String?
  // Normalized hosts for network fetch (just domain)
  let faviconPrimaryHost: String?
  let faviconSecondaryHost: String?
  let failureCount: Int
  let batchIds: [Int64]
}

struct CanvasTimelineDataView: View {
  @Binding var selectedDate: Date
  @Binding var selectedActivity: TimelineActivity?
  @Binding var scrollToNowTick: Int
  @Binding var hasAnyActivities: Bool
  @Binding var refreshTrigger: Int
  let contentLeadingInset: CGFloat
  @ObservedObject var zoom: DayTimelineZoomState
  private var hourHeight: CGFloat { DayTimelineZoom.hourHeight(for: zoom.percent) }
  let cardTextFontSize: CGFloat
  let cardTextFontWeight: Font.Weight
  let timeLabelFontSize: CGFloat
  let cardIconLeadingInset: CGFloat
  let cardIconTextSpacing: CGFloat
  let cardFaviconSize: CGFloat
  let cardFaviconVerticalOffset: CGFloat
  let cardCompactDurationThreshold: CGFloat
  let cardCompactVerticalPadding: CGFloat
  let cardNormalVerticalPadding: CGFloat
  let cardHoverScale: CGFloat
  let cardPressedScale: CGFloat
  // Categories turned off in the chip row; their cards render dimmed.
  var mutedCategoryKeys: Set<String> = []

  @Environment(\.dayflowTheme) private var theme
  @State private var selectedCardId: String? = nil
  @State private var positionedActivities: [CanvasPositionedActivity] = []
  @State private var recordingProjection: TimelineRecordingProjectionWindow?
  @State private var refreshTimer: Timer?
  @State private var didInitialScrollInView: Bool = false
  // Gate the ScrollView's visibility on whether the initial auto-scroll has
  // fired. Mirrors the Week view's fix for the "starts at 8 AM then flashes
  // to 10 AM" flicker. Only flips true once per mount; never flips back, so
  // date navigation within a mounted view doesn't re-hide content.
  @State private var hasPerformedInitialScroll: Bool = false
  @State private var loadTask: Task<Void, Never>?
  @State private var loadRevision = 0
  @State private var scrollTask: Task<Void, Never>?
  @State private var scrollRequest: DayTimelineScrollRequest?
  @State private var requestedReplayDate: Date?
  // Staggered entrance animation state (Emil Kowalski principle: sequential reveal)
  @State private var cardEntranceProgress: [String: Bool] = [:]
  // Plain reference box: mutating it never invalidates body, so hover
  // tracking cannot itself trigger a re-render during mouse handling.
  @State private var cardsHover = CardsHoverTracker()
  @ObservedObject private var pauseManager = PauseManager.shared
  @EnvironmentObject private var categoryStore: CategoryStore
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var retryCoordinator: RetryCoordinator

  private var timelineHeight: CGFloat {
    CGFloat(CanvasConfig.endHour - CanvasConfig.startHour) * hourHeight
  }

  private var recordingControlMode: RecordingControlMode {
    RecordingControl.currentMode(appState: appState, pauseManager: pauseManager)
  }

  // Locate the current minute, rather than a fixed number of hours above it:
  // two hours no longer fit in the viewport when a short event is magnified.
  private func scrollToNowCenteredHour() {
    timelinePerfLog("dayCanvas.scrollToNow tick=\(scrollToNowTick) hours=\(timelineMinutes(for: Date()) / 60)")
    let focus = replayFocusDate(for: selectedDate) ?? Date()
    scrollRequest = DayTimelineScrollRequest(
      hours: CGFloat(timelineMinutes(for: focus) / 60), viewportFraction: 0.5)
    // A parent scroll tick can cancel the delayed initial scroll. Any replacement
    // scroll must also reveal the canvas, or its content stays transparent.
    revealInitialScroll()
  }

  // `body` is split into two chained computed properties for the same reason
  // `MainView.mainLayout` is: the combined modifier chain + inline closures
  // was exceeding Swift's per-expression type-check budget. Closures with
  // meaningful bodies (onReceive, onDisappear, the outer onAppear) are
  // extracted to named methods below — each `some View` boundary + each
  // function boundary gives the solver a fresh anchor point.
  var body: some View {
    dayTimelineScrollContainer
      .background(Color.clear)
      .onAppear(perform: performDayTimelineOnAppear)
      .onDisappear(perform: performDayTimelineOnDisappear)
      .onChange(of: selectedDate) { loadActivities() }
      .onChange(of: refreshTrigger) { loadActivities() }
      .onReceive(NotificationCenter.default.publisher(for: .recordingReplayShowDate)) { notification in
        guard RecordingReplayPreview.isEnabled,
          let date = notification.object as? Date ?? notification.userInfo?["date"] as? Date
        else { return }
        requestedReplayDate = date
        scheduleReplayFocus(date)
      }
      .onReceive(NotificationCenter.default.publisher(for: .timelineCardsDidCommit).receive(on: DispatchQueue.main)) { _ in
        loadActivities(animate: false)
      }
      .onChange(of: appState.isRecording) { loadActivities(animate: false) }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        handleDayTimelineDidBecomeActive()
      }

  }

  // Native scroll container + scroll-trigger handlers. Held in its own `some
  // View` property so the outer chain above sees a single opaque type.
  // Visibility is gated on `hasPerformedInitialScroll` so the "starts at 8 AM
  // then flashes to 10 AM" flicker can't happen — the ScrollView stays
  // invisible until the first auto-scroll lands, then fades in.
  private var dayTimelineScrollContainer: some View {
    DayTimelineCanvasScrollView(
      zoom: zoom,
      navigationToken: "\(selectedDate.timeIntervalSinceReferenceDate)-\(scrollToNowTick)",
      scrollRequest: scrollRequest
    ) {
      timelineScrollContent()
    }
      .background(Color.clear)
      .opacity(hasPerformedInitialScroll ? 1 : 0)
      .onChange(of: scrollToNowTick) {
        scrollTask?.cancel()
        scrollToNowCenteredHour()
      }
      .onChange(of: hourHeight) {
        // A user zoom supersedes pending initial/date auto-scrolls.
        scrollTask?.cancel()
        didInitialScrollInView = true
        revealInitialScroll()
      }
      .onChange(of: positionedActivities.count) {
        guard !didInitialScrollInView, timelineIsToday(selectedDate) else { return }
        didInitialScrollInView = true
        scheduleScrollToNow(delay: 0.1)
      }
      .onAppear {
        if let date = replayFocusDate(for: selectedDate) {
          scheduleReplayFocus(date)
        } else if timelineIsToday(selectedDate) {
          scheduleScrollToNow(delay: 0.05)
        } else {
          // Past day: nothing to auto-scroll to. Reveal immediately so the
          // user sees the day's content as soon as it loads rather than
          // staring at a blank ScrollView.
          revealInitialScroll()
        }
      }
      .onChange(of: selectedDate) { _, newDate in
        scrollTask?.cancel()
        if let date = replayFocusDate(for: newDate) {
          scheduleReplayFocus(date)
          return
        }
        guard timelineIsToday(newDate) else {
          revealInitialScroll()
          return
        }
        didInitialScrollInView = false
        scheduleScrollToNow(delay: 0.1)
      }
  }

  private func replayFocusDate(for day: Date) -> Date? {
    guard RecordingReplayPreview.isEnabled else { return nil }
    if let requestedReplayDate,
      Calendar.current.isDate(timelineDisplayDate(from: requestedReplayDate), inSameDayAs: day) {
      return requestedReplayDate
    }
    return RecordingReplayPreview.windows.first(where: {
      Calendar.current.isDate(timelineDisplayDate(from: $0.start), inSameDayAs: day)
    })?.start
  }

  private func scheduleReplayFocus(_ date: Date) {
    scrollTask?.cancel()
    scrollTask = Task { @MainActor in
      // Date navigation and mounting the day canvas settle before applying its native scroll.
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled,
        Calendar.current.isDate(timelineDisplayDate(from: date), inSameDayAs: selectedDate)
      else { return }
      scrollRequest = DayTimelineScrollRequest(
        hours: CGFloat(timelineMinutes(for: date) / 60), viewportFraction: 0.25)
      revealInitialScroll()
    }
  }

  private func scheduleScrollToNow(delay: Double) {
    scrollTask?.cancel()
    scrollTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      scrollToNowCenteredHour()
    }
  }

  private func revealInitialScroll() {
    guard !hasPerformedInitialScroll else { return }
    withAnimation(.easeOut(duration: 0.18)) {
      hasPerformedInitialScroll = true
    }
  }

  // MARK: - Extracted body event handlers (type-checker load reduction)

  private func performDayTimelineOnAppear() {
    loadActivities()
    startRefreshTimer()
  }

  private func performDayTimelineOnDisappear() {
    stopRefreshTimer()
    scrollTask?.cancel()
    scrollTask = nil
    loadTask?.cancel()
    loadTask = nil
  }

  private func handleDayTimelineDidBecomeActive() {
    loadActivities(animate: false)
    if refreshTimer == nil {
      startRefreshTimer()
    }
  }

  @ViewBuilder
  private func timelineScrollContent() -> some View {
    ZStack(alignment: .topLeading) {
      // Transparent background to let panel show through
      Color.clear
      // Invisible anchor positioned for "now" scroll target
      nowAnchorView()
        .zIndex(-1)  // Behind other content

      // Hour lines layer
      hourLines
        .padding(.leading, CanvasConfig.timeColumnWidth)

      // Main content with time labels and cards
      mainTimelineRow

      // Current time indicator/status card (kept above cards so paused taps work)
      currentTimeIndicator
        .zIndex(10)
    }
    .frame(height: timelineHeight)
    .padding(.leading, contentLeadingInset)
    .background(Color.clear)
  }

  // Figma draws each hour line as a dashed hairline.
  private var hourLines: some View {
    VStack(spacing: 0) {
      ForEach(0..<(CanvasConfig.endHour - CanvasConfig.startHour), id: \.self) { _ in
        VStack(spacing: 0) {
          DashedHorizontalLine()
            .stroke(theme.hourLine, style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            .frame(height: 0.75)
          Spacer()
        }
        .frame(height: hourHeight)
      }
    }
  }

  /// Hour labels for hours that haven't happened yet (today only) are dimmed.
  private func hourLabelColor(for hour: Int) -> Color {
    guard timelineIsToday(selectedDate) else { return theme.hourLabel }
    let now = Calendar.current.component(.hour, from: Date())
    let nowIndex =
      now >= CanvasConfig.startHour
      ? now - CanvasConfig.startHour : (24 - CanvasConfig.startHour) + now
    let hourIndex = hour - CanvasConfig.startHour
    return hourIndex > nowIndex ? theme.hourLabelFuture : theme.hourLabel
  }

  private var timeColumn: some View {
    VStack(spacing: 0) {
      ForEach(CanvasConfig.startHour..<CanvasConfig.endHour, id: \.self) { hour in
        let hourIndex = hour - CanvasConfig.startHour
        Text(formatHour(hour))
          .font(.system(size: timeLabelFontSize))
          .foregroundColor(hourLabelColor(for: hour))
          .padding(.trailing, 5)
          .padding(.top, 2)
          .frame(width: CanvasConfig.timeColumnWidth, alignment: .trailing)
          .multilineTextAlignment(.trailing)
          .lineLimit(1)
          .minimumScaleFactor(0.95)
          .allowsTightening(true)
          .frame(height: hourHeight, alignment: .top)
          .offset(y: -8)
          .id("hour-\(hourIndex)")
      }
    }
    .frame(width: CanvasConfig.timeColumnWidth)
    .contentShape(Rectangle())
    .onTapGesture {
      clearSelection()
    }
    .pointingHandCursor(enabled: selectedCardId != nil || selectedActivity != nil)
  }

  private var cardsLayer: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture {
            clearSelection()
          }
          .pointingHandCursor(enabled: selectedCardId != nil || selectedActivity != nil)
        ForEach(Array(positionedActivities.enumerated()), id: \.element.id) { index, item in
          let height = DayTimelineZoom.cardHeight(
            minutes: item.durationMinutes, hourHeight: hourHeight)
          let yPosition = DayTimelineZoom.y(minutes: item.startMinutes, hourHeight: hourHeight) + 1
          let isVisible = cardEntranceProgress[item.id] ?? false
          CanvasActivityCard(
            title: item.title,
            time: item.timeLabel,
            height: height,
            durationMinutes: item.durationMinutes,
            style: style(for: item.categoryName),
            isSelected: selectedActivity.map { item.activity.id == $0.id } ?? false,
            isSystemCategory: item.categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
              .caseInsensitiveCompare("System") == .orderedSame,
            isBackupGenerated: item.activity.isBackupGenerated == true,
            onTap: {
              if let selectedActivity, item.activity.id == selectedActivity.id {
                clearSelection()
              } else {
                selectedCardId = item.id
                selectedActivity = item.activity
              }
            },
            faviconPrimaryRaw: item.faviconPrimaryRaw,
            faviconSecondaryRaw: item.faviconSecondaryRaw,
            faviconPrimaryHost: item.faviconPrimaryHost,
            faviconSecondaryHost: item.faviconSecondaryHost,
            statusLine: retryCoordinator.statusLine(for: item.batchIds),
            failureCount: item.failureCount,
            fontSize: cardTextFontSize,
            fontWeight: cardTextFontWeight,
            iconLeadingInset: cardIconLeadingInset,
            iconTextSpacing: cardIconTextSpacing,
            faviconSize: cardFaviconSize,
            faviconVerticalOffset: cardFaviconVerticalOffset,
            compactDurationThreshold: cardCompactDurationThreshold,
            compactVerticalPadding: cardCompactVerticalPadding,
            normalVerticalPadding: cardNormalVerticalPadding,
            hoverScale: cardHoverScale,
            pressedScale: cardPressedScale
          )
          .frame(width: geo.size.width, height: height)
          .position(x: geo.size.width / 2, y: yPosition + (height / 2))
          .opacity(mutedCategoryKeys.contains(categoryFilterKey(item.categoryName)) ? 0.25 : 1)
          .animation(.easeOut(duration: 0.15), value: mutedCategoryKeys)
          // Staggered entrance animation (Emil Kowalski: sequential reveal creates polish)
          .opacity(isVisible ? 1 : 0)
          .offset(x: isVisible ? 0 : 12)
          .animation(
            .spring(response: 0.35, dampingFraction: 0.8)
              .delay(Double(index) * 0.03),  // 30ms stagger between cards
            value: isVisible
          )
        }
      }
    }
    .frame(minWidth: 0, maxWidth: .infinity)
    .onHover { hovering in
      cardsHover.isHovering = hovering
      guard !hovering, cardsHover.pendingRefresh else { return }
      cardsHover.pendingRefresh = false
      // Leave the mouse event before mutating the card list.
      DispatchQueue.main.async {
        loadActivities(animate: false, deferWhileHovering: true)
      }
    }
  }

  private var mainTimelineRow: some View {
    HStack(spacing: 0) {
      timeColumn
      cardsLayer
    }
  }

  @ViewBuilder
  private var currentTimeIndicator: some View {
    if !RecordingReplayPreview.isEnabled, timelineIsToday(selectedDate), let projection = recordingProjection {
      switch recordingControlMode {
      case .active:
        let projectionHeight = recordingProjectionHeight(for: projection)
        let isCompactProjection = projectionHeight < 24
        timelineStatusCard(
          height: projectionHeight,
          yPosition: calculateYPosition(for: projection.start) + 1,
          gradient: theme.generatingGradient,
          gradientOpacity: 1.0,
          baseColor: theme.panelSolid,
          strokeColor: .clear,
          strokeWidth: 0,
          shadowColor: .clear,
          shadowRadius: 0
        ) {
          if !isCompactProjection {
            generatingStatusText
          }
        }
      case .pausedTimed, .pausedIndefinite:
        let projectionHeight = recordingProjectionHeight(for: projection)
        timelineStatusCard(
          height: projectionHeight,
          yPosition: calculateYPosition(for: projection.start) + 1,
          gradient: theme.pausedCardGradient,
          gradientOpacity: 1.0,
          baseColor: theme.panelSolid,
          strokeColor: theme.cardBorder.opacity(0.6),
          strokeWidth: 0.5,
          shadowColor: .clear,
          shadowRadius: 0,
          onTap: handlePausedStatusCardTap
        ) {
          pausedStatusText
        }
      case .stopped:
        let projectionHeight = recordingProjectionHeight(for: projection)
        timelineStatusCard(
          height: projectionHeight,
          yPosition: calculateYPosition(for: projection.start) + 1,
          gradient: theme.pausedCardGradient,
          gradientOpacity: 1.0,
          baseColor: theme.panelSolid,
          strokeColor: theme.cardBorder.opacity(0.6),
          strokeWidth: 0.5,
          shadowColor: .clear,
          shadowRadius: 0,
          onTap: handlePausedStatusCardTap
        ) {
          stoppedStatusText
        }
      }
    }
  }

  @ViewBuilder
  private func timelineStatusCard<Content: View>(
    height: CGFloat,
    yPosition: CGFloat,
    gradient: LinearGradient,
    gradientOpacity: Double,
    baseColor: Color,
    strokeColor: Color,
    strokeWidth: CGFloat,
    shadowColor: Color,
    shadowRadius: CGFloat,
    onTap: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 0) {
      content()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .frame(
      maxWidth: .infinity,
      minHeight: height,
      maxHeight: height,
      alignment: .leading
    )
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(baseColor)
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(gradient)
            .opacity(gradientOpacity)
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .inset(by: 0.375)
        .stroke(strokeColor, lineWidth: strokeWidth)
    )
    .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 0)
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .offset(y: yPosition)
    .padding(.leading, CanvasConfig.timeColumnWidth)
    .pointingHandCursor(enabled: onTap != nil)
    .onTapGesture {
      onTap?()
    }
    .allowsHitTesting(onTap != nil)
  }

  private var generatingStatusText: some View {
    HStack(spacing: 8) {
      TimelineThinkingSpinner(
        config: timelineSpinnerConfig,
        visualScale: 0.5
      )
      NextCardGenerationStatusText()
    }
    .font(
      Font.system(size: 12)
        .weight(.semibold)
    )
    .lineSpacing(2.4)
    .tracking(0)
    .foregroundColor(theme.accent)
    .lineLimit(1)
    .truncationMode(.tail)
  }

  private var pausedStatusText: some View {
    statusText(
      iconName: "pause.fill",
      message: String(
        localized: "Target Flow is paused. Click 'Resume' to generate new activity cards.")
    )
  }

  private var stoppedStatusText: some View {
    statusText(
      iconName: "play.fill",
      message: String(
        localized: "Target Flow isn't recording. Click 'Resume' to generate new activity cards.")
    )
  }

  private func statusText(iconName: String, message: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(theme.pausedCardText)
      Text(message)
    }
    .font(
      Font.system(size: 12)
        .weight(.regular)
    )
    .lineSpacing(2.4)
    .tracking(0)
    .foregroundColor(theme.pausedCardText)
    .lineLimit(1)
    .truncationMode(.tail)
  }

  @MainActor
  private func handlePausedStatusCardTap() {
    switch recordingControlMode {
    case .active:
      return
    case .pausedTimed, .pausedIndefinite:
      PauseManager.shared.resume()
    case .stopped:
      RecordingControl.start()
    }
  }

  private func clearSelection() {
    guard selectedCardId != nil || selectedActivity != nil else { return }
    selectedCardId = nil
    selectedActivity = nil
  }

  private var timelineSpinnerConfig: TimelineSpinnerConfig {
    var config = TimelineSpinnerConfig.reference
    config.gap = 1.0
    config.colorDim = .init(0.263, 0.365, 0.592)  // #435D97
    config.colorMid = .init(0.722, 0.518, 0.737)  // #B884BC
    config.colorHot = .init(0.965, 0.745, 0.455)  // #F6BE74
    return config
  }

  /// `deferWhileHovering`: background refreshes must not swap the card
  /// ForEach's items out from under the pointer. AppKit's mouseMoved hit-test
  /// can land mid-update and abort in AttributeGraph ("deleting updating
  /// attribute"), so hold the result until the pointer leaves the cards.
  private func loadActivities(animate: Bool = true, deferWhileHovering: Bool = false) {
    // Cancel any in-flight database read to prevent query pileup
    loadTask?.cancel()
    loadRevision += 1
    let requestedRevision = loadRevision
    timelinePerfLog("dayCanvas.load.begin revision=\(requestedRevision) animate=\(animate)")

    loadTask = Task.detached(priority: .userInitiated) {
      let calendar = Calendar.current

      // Normalize to noon so time components do not leak into day jumps
      let requestedSelectedDate = await MainActor.run { self.selectedDate }
      let logicalDate =
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: requestedSelectedDate)
        ?? requestedSelectedDate

      // Check for cancellation before expensive database read
      guard !Task.isCancelled else { return }

      // Shared loader handles the 4 AM boundary, failed-card filtering, and
      // card -> activity conversion (same path the Week view uses).
      let payload = TimelineActivityLoader.dayPayload(for: logicalDate)
      let dayString = payload.dayString

      // Check for cancellation before expensive processing
      guard !Task.isCancelled else { return }

      // Mitigation transform: resolve visual overlaps by trimming larger cards
      // so that smaller cards "win". This is a display-only fix to handle
      // upstream card-generation overlap bugs without touching stored data.
      let segments = TimelineActivityLoader.resolveDisplaySegments(from: payload.activities)
      let recordingProjection = TimelineActivityLoader.recordingProjectionWindow(
        for: payload.timelineDate,
        displaySegments: segments,
        now: Date()
      )

      let positioned = segments.map { seg -> CanvasPositionedActivity in
        let startMinutes = self.timelineMinutes(for: seg.start)
        let durationMinutes = max(0, seg.end.timeIntervalSince(seg.start) / 60)
        // Raw values for pattern matching, normalized for network fetch
        let primaryRaw = seg.activity.appSites?.primary
        let secondaryRaw = seg.activity.appSites?.secondary
        let primaryHost = FaviconService.normalizedHost(from: primaryRaw)
        let secondaryHost = FaviconService.normalizedHost(from: secondaryRaw)

        return CanvasPositionedActivity(
          id: seg.activity.id,
          activity: seg.selectionActivity,
          startMinutes: startMinutes,
          durationMinutes: durationMinutes,
          title: seg.displayTitle,
          timeLabel: self.formatRange(start: seg.start, end: seg.end),
          categoryName: seg.activity.category,
          faviconPrimaryRaw: primaryRaw,
          faviconSecondaryRaw: secondaryRaw,
          faviconPrimaryHost: primaryHost,
          faviconSecondaryHost: secondaryHost,
          failureCount: seg.failureCount,
          batchIds: seg.batchIds
        )
      }

      // Final cancellation check before updating UI
      guard !Task.isCancelled else { return }

      let currentDayString = await MainActor.run {
        DateFormatter.yyyyMMdd.string(
          from: timelineDisplayDate(from: self.selectedDate, now: Date()))
      }

      guard currentDayString == dayString else {
        timelinePerfLog(
          "dayTimeline.load.discardStale requestedDay=\(dayString) currentDay=\(currentDayString)"
        )
        return
      }

      await MainActor.run {
        guard !Task.isCancelled, self.loadRevision == requestedRevision,
          DateFormatter.yyyyMMdd.string(from: timelineDisplayDate(from: self.selectedDate, now: Date())) == dayString else {
          timelinePerfLog("dayCanvas.load.discard revision=\(requestedRevision) current=\(self.loadRevision)")
          return
        }
        timelinePerfLog("dayCanvas.load.commit revision=\(requestedRevision) cards=\(positioned.count) day=\(dayString)")
        if deferWhileHovering && self.cardsHover.isHovering {
          self.cardsHover.pendingRefresh = true
          return
        }
        self.cardsHover.pendingRefresh = false
        if animate {
          // Clear entrance progress for new activities (triggers stagger animation)
          self.cardEntranceProgress = [:]
        }
        self.positionedActivities = positioned
        self.recordingProjection = recordingProjection
        self.hasAnyActivities = !positioned.isEmpty
        if let selectedActivity {
          self.selectedActivity = TimelineActivityLoader.restoredSelection(
            selectedActivity, in: positioned.map(\.activity))
          self.selectedCardId = positioned.first(where: {
            $0.activity.id == selectedActivity.id
          })?.id
        }

        if animate {
          // Trigger staggered entrance animation after a brief layout delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard self.loadRevision == requestedRevision else { return }
            for activity in positioned {
              self.cardEntranceProgress[activity.id] = true
            }
          }
        } else {
          // Silent refresh: ensure all cards are visible immediately (no animation)
          for activity in positioned {
            self.cardEntranceProgress[activity.id] = true
          }
        }

        NotificationCenter.default.post(
          name: .timelineDataUpdated,
          object: nil,
          userInfo: ["dayString": dayString]
        )
      }
    }
  }

  private func recordingProjectionHeight(for projection: TimelineRecordingProjectionWindow)
    -> CGFloat
  {
    let durationMinutes = max(0, projection.end.timeIntervalSince(projection.start) / 60)
    return DayTimelineZoom.cardHeight(minutes: durationMinutes, hourHeight: hourHeight)
  }

  private func startRefreshTimer() {
    stopRefreshTimer()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
      loadActivities(animate: false, deferWhileHovering: true)
    }
  }

  private func stopRefreshTimer() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  private func calculateYPosition(for time: Date) -> CGFloat {
    DayTimelineZoom.y(minutes: timelineMinutes(for: time), hourHeight: hourHeight)
  }

  private func timelineMinutes(for time: Date) -> Double {
    let calendar = Calendar.current
    let hour = calendar.component(.hour, from: time)
    let minute = calendar.component(.minute, from: time)

    let hoursSince4AM: Int
    if hour >= CanvasConfig.startHour {
      hoursSince4AM = hour - CanvasConfig.startHour
    } else {
      hoursSince4AM = (24 - CanvasConfig.startHour) + hour
    }

    let totalMinutes = hoursSince4AM * 60 + minute
    return Double(totalMinutes)
  }

  private func formatHour(_ hour: Int) -> String {
    let normalizedHour = hour >= 24 ? hour - 24 : hour
    let date =
      Calendar.current.date(bySettingHour: normalizedHour, minute: 0, second: 0, of: Date())
      ?? Date()
    return cachedTimeFormatter.string(from: date)
  }

  private func formatRange(start: Date, end: Date) -> String {
    let s = cachedTimeFormatter.string(from: start)
    let e = cachedTimeFormatter.string(from: end)
    return "\(s) - \(e)"
  }

  private func style(for rawCategory: String) -> CanvasActivityCardStyle {
    let normalized = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let categories = categoryStore.categories
    let matched = categories.first {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }
    let category = TimelineEventDisplay.reservedCategory(rawCategory) ?? matched
    let baseNSColor = NSColor(hex: category?.colorHex ?? "#A0AEC0") ?? .systemGray

    return CanvasActivityCardStyle(
      text: theme.cardTitle,
      time: theme.cardTime,
      accent: Color(nsColor: baseNSColor),
      isIdle: category?.isIdle ?? false
    )
  }
}

private struct DashedHorizontalLine: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    return path
  }
}

extension CanvasTimelineDataView {
  // Places a hidden view at a position slightly above "now" so that scrolling reveals "now" plus more below
  @ViewBuilder
  private func nowAnchorView() -> some View {
    // Position anchor ABOVE current time for 80% down viewport positioning
    let yNow = calculateYPosition(for: Date())

    // Place anchor ~6 hours above current time
    // When scrolled to .top, this positions current time at ~80% down the viewport
    // Adjust hoursAbove to fine-tune: 5 = current time appears higher, 7 = lower
    let hoursAbove: CGFloat = 6
    let anchorY = yNow - (hoursAbove * hourHeight)

    // Create a frame that spans the full timeline height
    // Then position the anchor absolutely within it
    Color.clear
      .frame(
        width: 1,
        height: timelineHeight
      )
      .overlay(
        Rectangle()
          .fill(Color.red.opacity(0.001))
          .frame(width: 10, height: 20)
          .position(x: 5, y: anchorY)
          .id("nowAnchor"),
        alignment: .topLeading
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

#Preview("Canvas Timeline Data View") {
  struct PreviewWrapper: View {
    @StateObject private var zoom = DayTimelineZoomState()
    @State private var date = Date()
    @State private var selected: TimelineActivity? = nil
    @State private var tick: Int = 0
    @State private var refresh: Int = 0
    var body: some View {
      CanvasTimelineDataView(
        selectedDate: $date,
        selectedActivity: $selected,
        scrollToNowTick: $tick,
        hasAnyActivities: .constant(true),
        refreshTrigger: $refresh,
        contentLeadingInset: 0,
        zoom: zoom,
        cardTextFontSize: TimelineTypography.cardTextFontSize,
        cardTextFontWeight: TimelineTypography.cardTextFontWeight,
        timeLabelFontSize: TimelineTypography.timeLabelFontSize,
        cardIconLeadingInset: TimelineCardLayout.iconLeadingInset,
        cardIconTextSpacing: TimelineCardLayout.iconTextSpacing,
        cardFaviconSize: TimelineCardLayout.faviconSize,
        cardFaviconVerticalOffset: TimelineCardLayout.faviconVerticalOffset,
        cardCompactDurationThreshold: TimelineCardLayout.compactDurationThreshold,
        cardCompactVerticalPadding: TimelineCardLayout.compactVerticalPadding,
        cardNormalVerticalPadding: TimelineCardLayout.normalVerticalPadding,
        cardHoverScale: TimelineCardLayout.hoverScale,
        cardPressedScale: TimelineCardLayout.pressedScale
      )
      .frame(width: 800, height: 600)
      .environmentObject(CategoryStore())
      .environmentObject(AppState.shared)
      .environmentObject(RetryCoordinator())
    }
  }
  return PreviewWrapper()
}

// Only touched on the main thread (onHover and MainActor.run in loadActivities).
private final class CardsHoverTracker {
  var isHovering = false
  var pendingRefresh = false
}
