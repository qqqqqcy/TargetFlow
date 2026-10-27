//
//  Layout+Panels.swift
//  Dayflow
//

import SwiftUI

struct TimelineCalendarButtonFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

enum TimelineAlignment {
  static let topInset: CGFloat = 24
  static let pickerRowOffset: CGFloat = -10
  static let categoryRowInset: CGFloat = 55
  static let headerContentGap: CGFloat = 18
}

enum TimelineNavigationLayout {
  static let arrowSize: CGFloat = 24
  static let hoverCircleSize = DayflowLayout.buttonHeight
  static let calendarGap: CGFloat = 4
}

enum LogoPosition {
  static let logoSize: CGFloat = 48
  static let logoVerticalOffset: CGFloat = 8
}

extension MainView {
  var contentStack: some View {
    // Two-column layout: left logo + sidebar; right white panel with header, filters, timeline
    HStack(alignment: .top, spacing: 0) {
      leftColumn
      rightPanel
    }
    .padding(0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var leftColumn: some View {
    VStack(alignment: .leading, spacing: 28) {
      Text("targetflow")
        .font(.system(size: 24, weight: .bold, design: .rounded))
        .tracking(-1)
        .foregroundStyle(.white)
        .padding(.leading, 22)
        .padding(.top, 54)

      SidebarView(selectedIcon: $selectedIcon)
        .opacity(sidebarOpacity)

      Spacer(minLength: 16)

      VStack(alignment: .leading, spacing: 8) {
        Label(
          appState.isRecording ? String(localized: "Recording screen") : String(localized: "Recording paused"),
          systemImage: appState.isRecording ? "record.circle" : "pause.circle"
        )
        .font(.system(size: 11, weight: .semibold))
        Text(String(localized: "Track your time, focus on your goals"))
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.78))
      }
      .foregroundStyle(.white)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.18)))
      .padding(.horizontal, 16)

      Text(
        "Target Flow · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
      )
      .font(.system(size: 10))
      .foregroundStyle(.white.opacity(0.8))
      .padding(.horizontal, 22)
      .padding(.bottom, 18)
    }
    .frame(width: 166)
    .frame(maxHeight: .infinity)
    .background { TopographicFlowBackground() }
  }

  @ViewBuilder
  private var rightPanel: some View {
    // Right column: Main white panel including header + content
    ZStack {
      switch selectedIcon {
      case .settings:
        SettingsView()
          .transition(DayflowMotion.transition(reduceMotion: reduceMotion))
      case .timeline:
        GeometryReader { geo in
          timelinePanel(geo: geo)
        }
        .transition(DayflowMotion.transition(reduceMotion: reduceMotion))
      }
    }
    .animation(reduceMotion ? .easeOut(duration: 0.12) : DayflowMotion.content, value: selectedIcon)
    .padding(0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .background { mainPanelBackground }
  }

  private var mainPanelBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    return
      shape
      .fill(theme.panelFill)
      .overlay(
        // Light-mode-only inner shadow (white 25%, 4px fade); dark keeps
        // its shipped panel look.
        InnerGlow(shape: shape, color: theme.isDark ? .clear : theme.panelInnerGlow, radius: 4)
      )
      .overlay(shape.strokeBorder(theme.panelBorder, lineWidth: 1))
      .shadow(color: theme.panelShadow, radius: 12, x: 0, y: 0)
  }

  private func timelinePanel(geo: GeometryProxy) -> some View {
    let showsCalendar = geo.size.width >= 1020 && timelineMode == .day
    return VStack(alignment: .leading, spacing: DayflowLayout.sectionSpacing) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 6) {
          Text(String(localized: "Timeline"))
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(theme.textPrimary)
          Text(String(localized: "See where your time goes and focus on your current goals."))
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
        }
        Spacer()
        PausePillView()
      }

      CurrentGoalsStatusView(onManageEvents: { showCategoryEditor = true })

      HStack(alignment: .top, spacing: DayflowLayout.columnSpacing) {
        if showsCalendar {
          timelineCalendarRail
        }
        timelineLeftColumn(showsFilters: !showsCalendar)
          .zIndex(1)
        if timelineInspectorWidth > 0 {
          timelineRightColumn(geo: geo)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, DayflowLayout.pageHorizontalInset)
    .padding(.top, DayflowLayout.pageTopInset)
    .padding(.bottom, DayflowLayout.pageBottomInset)
    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    .coordinateSpace(name: "TimelinePanel")
    .overlay(alignment: .topLeading) {
      timelineCalendarPopoverOverlay(panelWidth: geo.size.width)
    }
    .onPreferenceChange(TimelineCalendarButtonFramePreferenceKey.self) { frame in
      timelineCalendarButtonFrame = frame
    }
  }

  private var timelineCalendarRail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        TimelineCalendarPopover(
          isPresented: .constant(true),
          selectedDate: selectedDate,
          canSelectFutureDates: false,
          highlightsSelectedWeek: false,
          onSelect: { navigateTimeline(to: $0, method: "picker") },
          isEmbedded: true
        )
        Rectangle().fill(theme.separator).frame(height: 1)
        Text(String(localized: "Event filters"))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.textPrimary)
        categoryFilters(isVertical: true)
        Text(String(localized: "Click an event to dim its cards.\nDrag events to reorder them."))
          .font(.system(size: 10))
          .foregroundStyle(theme.textMuted)
          .lineSpacing(4)
      }
      .padding(14)
    }
    .scrollIndicators(.never)
    .frame(width: 216)
    .dayflowPanel()
  }

  private func timelineLeftColumn(showsFilters: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      timelineHeader
      if showsFilters {
        categoryFilters(isVertical: false)
          .padding(.horizontal, 12)
      }
      timelineContent
      timelineFooter
    }
    .padding(.top, 12)
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .dayflowPanel()
    .coordinateSpace(name: "TimelinePane")
    .onPreferenceChange(TimelineTimeLabelFramesPreferenceKey.self) { frames in
      timelineTimeLabelFrames = frames
    }
    .onPreferenceChange(WeeklyHoursFramePreferenceKey.self) { frame in
      DispatchQueue.main.async { weeklyHoursFrame = frame }
    }
  }

  private func categoryFilters(isVertical: Bool) -> some View {
    TabFilterBar(
      categories: categoryStore.editableCategories,
      idleCategory: categoryStore.idleCategory,
      mutedCategoryKeys: $mutedCategoryKeys,
      onMoveCategory: { id, targetID in
        categoryStore.moveCategory(id: id, toPositionOf: targetID)
      },
      isVertical: isVertical
    )
  }

  private var timelineContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .topLeading) {
        switch timelineMode {
        case .day:
          CanvasTimelineDataView(
            selectedDate: $selectedDate,
            selectedActivity: $selectedActivity,
            scrollToNowTick: $scrollToNowTick,
            hasAnyActivities: $hasAnyActivities,
            refreshTrigger: $refreshActivitiesTrigger,
            weeklyHoursFrame: weeklyHoursFrame,
            weeklyHoursIntersectsCard: $weeklyHoursIntersectsCard,
            contentLeadingInset: 0,
            hourHeight: TimelineScale.hourHeight,
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
            cardPressedScale: TimelineCardLayout.pressedScale,
            mutedCategoryKeys: mutedCategoryKeys
          )
          // Keep the day/week zoom subtle so text stays steady during the switch.
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
          .zIndex(timelineMode == .day ? 1 : 0)

        case .week:
          GeometryReader { gridGeometry in
            ScrollView(.horizontal) {
              WeekTimelineGridView(
                selectedDate: $selectedDate,
                selectedActivity: $selectedActivity,
                hasAnyActivities: $hasAnyActivities,
                refreshTrigger: $refreshActivitiesTrigger,
                weekRange: timelineWeekRange,
                onSelectActivity: selectTimelineActivity,
                onClearSelection: { clearTimelineSelection() },
                weeklyHoursFrame: weeklyHoursFrame,
                weeklyHoursIntersectsCard: $weeklyHoursIntersectsCard,
                hideCardsForModeSwitch: hideWeekCardsDuringModeSwitch,
                mutedCategoryKeys: mutedCategoryKeys
              )
              .frame(
                width: max(700, gridGeometry.size.width),
                height: gridGeometry.size.height
              )
            }
          }
          // The inverse zoom preserves the sense of pulling back to see a week.
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
          .zIndex(timelineMode == .week ? 1 : 0)
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .environmentObject(categoryStore)
      .opacity(contentOpacity)
      .animation(timelineModeContentAnimation, value: timelineMode)
    }
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var cardsToReviewPromptCount: Int {
    guard cardsToReviewCount > 0 else { return 0 }
    if hasRecentTimelineReviewRating || hasAnyTimelineReviewRating == false {
      return cardsToReviewCount
    }
    return 0
  }

  private var timelineFooter: some View {
    let weeklyHoursOpacity = 1.0
    let reviewPromptCount = cardsToReviewPromptCount

    return VStack(spacing: 8) {
      HStack(alignment: .center) {
        weeklyHoursText
          .opacity(contentOpacity * weeklyHoursOpacity)

        Spacer()

        copyTimelineButton
          .opacity(contentOpacity)
      }
      .padding(.horizontal, 12)

      if timelineMode == .day, reviewPromptCount > 0 {
        CardsToReviewButton(count: reviewPromptCount) {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showTimelineReview = true
          }
        }
        .opacity(contentOpacity)
      }
    }
    .padding(.vertical, 10)
    .background(theme.surfaceFill)
    .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
    .allowsHitTesting(true)
  }

  // Figma: the right panel is its own inset card (5pt from the panel edges,
  // 6pt radius, hairline border) rather than a flush column.
  private func timelineRightColumn(geo: GeometryProxy) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    let inset: CGFloat = 0

    return ZStack(alignment: .topLeading) {
      switch timelineMode {
      case .day:
        dayTimelineInspectorContent(geo: geo)
          .animation(
            reduceMotion ? .easeOut(duration: 0.12) : DayflowMotion.content,
            value: selectedActivity?.id
          )
      case .week:
        weekTimelineInspectorContent(geo: geo)
      }
    }
    .frame(width: max(0, timelineInspectorWidth - inset))
    .frame(maxHeight: .infinity)
    .clipShape(shape)
    .background {
      if timelineInspectorWidth > 0 {
        shape
          .fill(theme.rightPanelFill)
          .overlay(shape.strokeBorder(theme.rightPanelBorder, lineWidth: 0.75))
          .shadow(color: theme.rightPanelShadow, radius: 4, x: 0, y: 0)
      }
    }
    .contentShape(shape)
    .padding(.vertical, inset)
    .padding(.trailing, inset)
    .frame(width: timelineInspectorWidth)
    .opacity(contentOpacity)
  }

  @ViewBuilder
  private func dayTimelineInspectorContent(geo: GeometryProxy) -> some View {
    let reviewPromptCount = cardsToReviewPromptCount

    if let activity = selectedActivity {
      timelineActivityInspector(activity: activity, geo: geo)
        .transition(DayflowMotion.transition(reduceMotion: reduceMotion))
    } else {
      VStack(spacing: 0) {
        daySummary(reviewPromptCount: reviewPromptCount)
      }
      .transition(DayflowMotion.transition(reduceMotion: reduceMotion))
    }
  }

  private func daySummary(reviewPromptCount: Int) -> some View {
    DaySummaryView(
      selectedDate: selectedDate,
      categories: categoryStore.categories,
      storageManager: StorageManager.shared,
      cardsToReviewCount: reviewPromptCount,
      reviewRefreshToken: reviewSummaryRefreshToken,
      recordingControlMode: RecordingControl.currentMode(
        appState: appState,
        pauseManager: pauseManager
      ),
      onReviewTap: {
        guard reviewPromptCount > 0 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
          showTimelineReview = true
        }
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func weekTimelineInspectorContent(geo: GeometryProxy) -> some View {
    if let activity = selectedActivity, isWeekTimelineInspectorVisible {
      timelineActivityInspector(activity: activity, geo: geo)
        .id(activity.id)
        .opacity(weekInspectorContentVisible ? 1 : 0)
        .offset(x: weekInspectorContentVisible ? 0 : 10)
        .animation(inspectorContentAnimation, value: weekInspectorContentVisible)
        .transition(.opacity.combined(with: .offset(x: 10)))
    }
  }

  private func timelineActivityInspector(activity: TimelineActivity, geo: GeometryProxy)
    -> some View
  {
    VStack(spacing: 0) {
      HStack {
        Text(String(localized: "Event details")).font(.system(size: 12, weight: .semibold))
        Spacer()
        Button {
          clearTimelineSelection()
        } label: {
          Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            .frame(width: DayflowLayout.buttonHeight, height: DayflowLayout.buttonHeight)
            .background(
              theme.surfaceMuted,
              in: RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius)
            )
        }
        .buttonStyle(.plain)
        .help(String(localized: "Close event details"))
        .pointingHandCursor()
      }
      .foregroundStyle(theme.textSecondary)
      .padding(.horizontal, 16)
      .padding(.top, 12)
      ZStack(alignment: .bottom) {
        ActivityCard(
          activity: activity,
          maxHeight: geo.size.height,
          scrollSummary: true,
          hasAnyActivities: hasAnyActivities,
          onCategoryChange: { category, activity in
            handleCategoryChange(to: category, for: activity)
          },
          onTitleChange: { newTitle, activity in
            handleTitleChange(to: newTitle, for: activity)
          },
          onNavigateToCategoryEditor: {
            showCategoryEditor = true
          },
          onRetryBatchCompleted: { batchId in
            refreshActivitiesTrigger &+= 1
            if selectedActivity?.batchId == batchId {
              clearTimelineSelection()
            }
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!feedbackModalVisible)
        .padding(.bottom, rateSummaryFooterHeight)

        if !feedbackModalVisible {
          TimelineRateSummaryView(
            activityID: activity.id,
            onRate: handleTimelineRating,
            onDelete: handleTimelineDelete
          )
          .frame(maxWidth: .infinity)
          .allowsHitTesting(!feedbackModalVisible)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottomLeading) {
      if let direction = feedbackDirection, feedbackModalVisible {
        TimelineFeedbackModal(
          message: $feedbackMessage,
          shareLogs: $feedbackShareLogs,
          direction: direction,
          mode: feedbackMode,
          content: .timeline,
          onSubmit: handleFeedbackSubmit,
          onClose: { dismissFeedbackModal() }
        )
        .padding(.leading, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }

  private var weeklyHoursFadeOpacity: Double {
    guard weeklyHoursFrame != .zero, !timelineTimeLabelFrames.isEmpty else { return 1 }
    var maxOverlap: CGFloat = 0
    for frame in timelineTimeLabelFrames {
      let intersection = weeklyHoursFrame.intersection(frame)
      if !intersection.isNull {
        maxOverlap = max(maxOverlap, intersection.height)
      }
    }
    guard maxOverlap > 0 else { return 1 }
    let clamped = min(maxOverlap, weeklyHoursFadeDistance)
    return Double(1 - (clamped / weeklyHoursFadeDistance))
  }

  private var weeklyHoursText: some View {
    let textColor = theme.textTertiary
    let parts = timelineTrackedMinutesParts

    return HStack(spacing: 6) {
      (Text(parts.bold)
        .font(Font.custom("Figtree", size: 11).weight(.bold))
        + Text(parts.rest)
        .font(Font.custom("Figtree", size: 11).weight(.regular)))
      TimelineUsageCostView()
        .font(Font.custom("Figtree", size: 11).weight(.regular))
    }
    .foregroundColor(textColor)
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: WeeklyHoursFramePreferenceKey.self,
          value: proxy.frame(in: .named("TimelinePane"))
        )
      }
    )
  }

  private var copyTimelineButton: some View {
    let background = theme.secondaryButtonFill
    let stroke = theme.secondaryButtonBorder
    let textColor = theme.secondaryButtonText

    // Slide up + fade: no text scaling (scaling distorts letterforms)
    let enterTransition = AnyTransition.opacity
      .combined(with: .move(edge: .bottom))
    let exitTransition = AnyTransition.opacity
      .combined(with: .move(edge: .top))

    return Button(action: copyTimelineToClipboard) {
      ZStack {
        if copyTimelineState == .copying {
          ProgressView()
            .scaleEffect(0.6)
            .progressViewStyle(CircularProgressViewStyle(tint: textColor))
            .transition(.asymmetric(insertion: enterTransition, removal: exitTransition))
        } else if copyTimelineState == .copied {
          HStack(spacing: 4) {
            Image(systemName: "checkmark")
              .font(.system(size: 11.5, weight: .medium))
            Text("Copied")
              .font(Font.system(size: 13, weight: .semibold))
          }
          .transition(.asymmetric(insertion: enterTransition, removal: exitTransition))
        } else {
          HStack(spacing: 4) {
            Image("Copy")
              .resizable()
              .interpolation(.high)
              .renderingMode(.template)
              .scaledToFit()
              .frame(width: 11.5, height: 11.5)
            Text("Copy timeline")
              .font(Font.system(size: 13, weight: .semibold))
          }
          .transition(.asymmetric(insertion: enterTransition, removal: exitTransition))
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.85), value: copyTimelineState)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, DayflowLayout.buttonHorizontalInset)
      .frame(height: DayflowLayout.buttonHeight)
      .foregroundColor(textColor)
      .background(background)
      .background {
        if theme.isDark {
          Rectangle().fill(.ultraThinMaterial)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius))
      .overlay(
        RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius)
          .strokeBorder(stroke, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(ShrinkButtonStyle())
    .disabled(copyTimelineState == .copying)
    .hoverScaleEffect(
      enabled: copyTimelineState != .copying,
      scale: 1.02
    )
    .pointingHandCursorOnHover(
      enabled: copyTimelineState != .copying,
      reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Copy timeline to clipboard"))
  }
}

private struct ShrinkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .dayflowPressScale(
        configuration.isPressed,
        pressedScale: 0.97,
        animation: .spring(response: 0.25, dampingFraction: 0.7)
      )
  }
}
