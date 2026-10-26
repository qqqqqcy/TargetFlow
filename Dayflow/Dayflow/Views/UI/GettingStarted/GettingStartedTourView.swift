//
//  GettingStartedTourView.swift
//  Dayflow
//
//  Four-page welcome tour shown once, right after onboarding. It explains
//  what happens in the background, what a timeline card is, what unlocks
//  over time, and that it's fine to close the window while the first cards
//  are being made.
//

import SwiftUI
import UserNotifications

struct GettingStartedTourOverlay: View {
  @Environment(\.dayflowTheme) private var theme
  /// True when reopened from Settings rather than shown after onboarding.
  var isReplay = false
  let onFinish: () -> Void

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .ignoresSafeArea()
      theme.sheetOverlay
        .ignoresSafeArea()

      GettingStartedTourView(isReplay: isReplay, onFinish: onFinish)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
  }
}

private enum TourPage: Int, CaseIterable {
  case recording
  case cards
  case unlocks
  case closeWindow

  var analyticsName: String {
    switch self {
    case .recording: return "recording"
    case .cards: return "cards"
    case .unlocks: return "unlocks"
    case .closeWindow: return "close_window"
    }
  }

  var title: String {
    switch self {
    case .recording:
      return String(localized: "Target Flow is running in the background")
    case .cards:
      return String(localized: "Every 15 minutes, your day writes itself")
    case .unlocks:
      return String(localized: "The longer it runs, the more it can tell you")
    case .closeWindow:
      return String(localized: "You can close this window now")
    }
  }

  var body: String {
    switch self {
    case .recording:
      return String(
        localized:
          "It quietly records your screen while you work and keeps the recordings on this Mac. Pause or resume anytime from the Target Flow icon in your menu bar."
      )
    case .cards:
      return String(
        localized:
          "Your AI turns each stretch of screen time into timeline cards: what you worked on, the apps you used, and when you got pulled away. Click any card to see the full summary and a timelapse, or to fix its category."
      )
    case .unlocks:
      return String(
        localized:
          "Some views need enough of your day to say something useful, so they unlock as Target Flow records. Here's what's on the way."
      )
    case .closeWindow:
      return String(
        localized:
          "Target Flow keeps working from your menu bar. Your first cards usually show up about 15 minutes after recording starts, and we can send you a notification when they're ready."
      )
    }
  }
}

private enum TourNotificationState {
  case unknown
  case notDetermined
  case enabled
  case denied
}

struct GettingStartedTourView: View {
  @Environment(\.dayflowTheme) private var theme

  var isReplay = false
  let onFinish: () -> Void

  @State private var page: TourPage = .recording
  @State private var notificationState: TourNotificationState = .unknown
  @State private var isRequestingNotifications = false
  @State private var didFinish = false

  private enum Design {
    static let cardWidth: CGFloat = 620
    static let cardHeight: CGFloat = 520
    static let illustrationHeight: CGFloat = 216
    static let cornerRadius: CGFloat = 18
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      illustration
        .frame(maxWidth: .infinity)
        .frame(height: Design.illustrationHeight)
        .background(theme.sheetInnerBoxFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.sheetInnerBoxBorder, lineWidth: 1)
        )

      pageText
        .padding(.top, 26)
        .padding(.horizontal, 6)

      Spacer(minLength: 16)

      footer
    }
    .padding(22)
    .frame(width: Design.cardWidth, height: Design.cardHeight)
    .background(theme.panelSolid)
    .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
        .strokeBorder(theme.sheetCardBorder, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.18), radius: 30, x: 0, y: 14)
    .onAppear {
      AnalyticsService.shared.capture("getting_started_tour_shown", ["replay": isReplay])
      trackPageViewed(page)
      loadNotificationState()
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var illustration: some View {
    ZStack {
      switch page {
      case .recording:
        TourRecordingIllustration()
      case .cards:
        TourCardsIllustration()
      case .unlocks:
        TourUnlocksIllustration()
      case .closeWindow:
        TourNotificationIllustration()
      }
    }
    .id(page)
    .transition(.opacity.combined(with: .scale(scale: 0.97)))
  }

  private var pageText: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(page.rawValue + 1) of \(TourPage.allCases.count)")
        .font(.custom("Figtree", size: 12))
        .fontWeight(.semibold)
        .foregroundColor(theme.accentText)

      Text(page.title)
        .font(.custom("InstrumentSerif-Regular", size: 32))
        .tracking(-0.6)
        .foregroundColor(theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)

      Text(page.body)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(theme.textSecondary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .id(page)
    .transition(.opacity.combined(with: .offset(y: 6)))
  }

  private var footer: some View {
    HStack(spacing: 12) {
      pageDots

      Spacer()

      if page == .closeWindow {
        closeWindowButtons
      } else {
        Button("Skip tour", action: skip)
          .buttonStyle(.plain)
          .font(.custom("Figtree", size: 13))
          .foregroundColor(theme.textMuted)
          .pointingHandCursor()

        if page != .recording {
          secondaryButton(title: String(localized: "Back"), action: goBack)
        }

        primaryButton(title: String(localized: "Next"), action: goForward)
      }
    }
  }

  @ViewBuilder
  private var closeWindowButtons: some View {
    switch notificationState {
    case .notDetermined, .unknown:
      secondaryButton(title: String(localized: "Not now")) {
        finish(notificationChoice: "not_now")
      }
      primaryButton(title: String(localized: "Notify me when they're ready")) {
        requestNotificationsAndFinish()
      }
      .opacity(isRequestingNotifications ? 0.6 : 1)
      .allowsHitTesting(!isRequestingNotifications)
    case .enabled:
      primaryButton(title: String(localized: "Got it")) {
        finish(notificationChoice: "already_enabled")
      }
    case .denied:
      primaryButton(title: String(localized: "Got it")) {
        finish(notificationChoice: "previously_denied")
      }
    }
  }

  private var pageDots: some View {
    HStack(spacing: 6) {
      ForEach(TourPage.allCases, id: \.rawValue) { dotPage in
        Capsule()
          .fill(dotPage == page ? theme.accent : theme.textMuted.opacity(0.35))
          .frame(width: dotPage == page ? 18 : 6, height: 6)
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: page)
  }

  private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
    DayflowSurfaceButton(
      action: action,
      content: {
        Text(title)
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
      },
      background: theme.primaryButtonFill,
      foreground: theme.primaryButtonText,
      borderColor: theme.primaryButtonBorder,
      cornerRadius: 999,
      horizontalPadding: 20,
      verticalPadding: 9,
      showOverlayStroke: true,
      innerGlowColor: theme.primaryButtonInnerGlow
    )
  }

  private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
    DayflowSurfaceButton(
      action: action,
      content: {
        Text(title)
          .font(.custom("Figtree", size: 13))
          .fontWeight(.medium)
      },
      background: theme.secondaryButtonFill,
      foreground: theme.secondaryButtonText,
      borderColor: theme.secondaryButtonBorder,
      cornerRadius: 999,
      horizontalPadding: 16,
      verticalPadding: 9,
      showShadow: false
    )
  }

  // MARK: - Actions

  private func goForward() {
    guard let next = TourPage(rawValue: page.rawValue + 1) else { return }
    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
      page = next
    }
    trackPageViewed(next)
  }

  private func goBack() {
    guard let previous = TourPage(rawValue: page.rawValue - 1) else { return }
    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
      page = previous
    }
  }

  private func skip() {
    guard !didFinish else { return }
    didFinish = true
    AnalyticsService.shared.capture(
      "getting_started_tour_skipped", ["page": page.analyticsName, "replay": isReplay])
    onFinish()
  }

  private func finish(notificationChoice: String) {
    guard !didFinish else { return }
    didFinish = true
    AnalyticsService.shared.capture(
      "getting_started_tour_completed",
      ["notification_choice": notificationChoice, "replay": isReplay])
    onFinish()
  }

  private func requestNotificationsAndFinish() {
    isRequestingNotifications = true
    Task {
      let granted = await NotificationService.shared.requestPermission()
      isRequestingNotifications = false
      finish(notificationChoice: granted ? "granted" : "denied")
    }
  }

  private func loadNotificationState() {
    Task {
      let status = await NotificationService.shared.authorizationStatus()
      switch status {
      case .authorized, .provisional:
        notificationState = .enabled
      case .denied:
        notificationState = .denied
      default:
        notificationState = .notDetermined
      }
    }
  }

  private func trackPageViewed(_ viewedPage: TourPage) {
    AnalyticsService.shared.capture(
      "getting_started_tour_step_viewed",
      [
        "page": viewedPage.analyticsName, "page_index": viewedPage.rawValue, "replay": isReplay,
      ])
  }
}

// MARK: - Illustrations

/// A little menu bar with the Dayflow menu open, so people know where to find it later.
private struct TourRecordingIllustration: View {
  @Environment(\.dayflowTheme) private var theme
  @State private var isPulsing = false

  var body: some View {
    VStack(spacing: 0) {
      menuBar

      HStack {
        Spacer()
        menu
          .padding(.trailing, 92)
      }
      .padding(.top, 6)

      Spacer(minLength: 0)
    }
    .padding(.top, 18)
    .padding(.horizontal, 18)
    .onAppear {
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
        isPulsing = true
      }
    }
  }

  private var menuBar: some View {
    HStack(spacing: 14) {
      Image(systemName: "apple.logo")
        .font(.system(size: 12))
      Spacer()
      Image("TargetFlowLogoMainApp")
        .resizable()
        .renderingMode(.original)
        .scaledToFit()
        .frame(width: 16, height: 16)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.textPrimary.opacity(0.12)))
      Image(systemName: "wifi")
        .font(.system(size: 11))
      Image(systemName: "battery.75percent")
        .font(.system(size: 12))
      Text("9:41")
        .font(.custom("Figtree", size: 12))
        .fontWeight(.medium)
    }
    .foregroundColor(theme.textPrimary.opacity(0.8))
    .padding(.horizontal, 14)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.popoverFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.popoverBorder, lineWidth: 1)
    )
  }

  private var menu: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Circle()
          .fill(Color(hex: "E5483B"))
          .frame(width: 8, height: 8)
          .overlay(
            Circle()
              .stroke(Color(hex: "E5483B").opacity(0.5), lineWidth: 2)
              .scaleEffect(isPulsing ? 2.2 : 1)
              .opacity(isPulsing ? 0 : 1)
          )
        Text("Recording")
          .font(.custom("Figtree", size: 12))
          .fontWeight(.semibold)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)

      menuRow(symbol: "pause.fill", title: String(localized: "Pause Target Flow"))
      menuRow(symbol: "macwindow", title: String(localized: "Open Target Flow"))
    }
    .foregroundColor(theme.textPrimary)
    .padding(5)
    .frame(width: 180, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(theme.popoverFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.popoverBorder, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 6)
  }

  private func menuRow(symbol: String, title: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 10))
        .frame(width: 12)
        .foregroundColor(theme.textSecondary)
      Text(title)
        .font(.custom("Figtree", size: 12))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}

/// Mock timeline cards dropping in one after another.
private struct TourCardsIllustration: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visibleCount = 0

  private struct SampleCard {
    let time: String
    let title: String
    let detail: String
    let colorHex: String
  }

  private let samples: [SampleCard] = [
    SampleCard(
      time: "9:00", title: String(localized: "Reviewing pull requests"),
      detail: "GitHub · Slack", colorHex: "5B8DEF"),
    SampleCard(
      time: "9:15", title: String(localized: "Planning the week"),
      detail: "Notion · Calendar", colorHex: "43B581"),
    SampleCard(
      time: "9:30", title: String(localized: "Pulled into YouTube"),
      detail: String(localized: "Distraction · 6 min"), colorHex: "F28C38"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
        HStack(spacing: 12) {
          Text(sample.time)
            .font(.custom("Figtree", size: 11))
            .foregroundColor(theme.hourLabel)
            .frame(width: 34, alignment: .trailing)

          card(sample)
            .opacity(index < visibleCount ? 1 : 0)
            .offset(y: index < visibleCount ? 0 : -10)
            .scaleEffect(index < visibleCount ? 1 : 0.97, anchor: .top)
        }
      }
    }
    .padding(.horizontal, 60)
    .task {
      if reduceMotion {
        visibleCount = samples.count
        return
      }
      for index in samples.indices {
        try? await Task.sleep(for: .milliseconds(index == 0 ? 250 : 450))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
          visibleCount = index + 1
        }
      }
    }
  }

  private func card(_ sample: SampleCard) -> some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 2)
        .fill(Color(hex: sample.colorHex))
        .frame(width: 4, height: 30)

      VStack(alignment: .leading, spacing: 2) {
        Text(sample.title)
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
          .foregroundColor(theme.cardTitle)
        Text(sample.detail)
          .font(.custom("Figtree", size: 11))
          .foregroundColor(theme.cardTime)
      }

      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.cardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(theme.cardBorder, lineWidth: 1)
    )
  }
}

/// The unlock ladder: what becomes available after how much recorded time.
private struct TourUnlocksIllustration: View {
  @Environment(\.dayflowTheme) private var theme

  private struct Milestone {
    let badge: String
    let title: String
    let symbol: String
  }

  private var milestones: [Milestone] {
    [
      Milestone(
        badge: String(localized: "~15 min"),
        title: String(localized: "First cards on your timeline"),
        symbol: "rectangle.stack"),
      Milestone(
        badge: String(localized: "\(FeatureAccessRequirements.dailyRequiredHours) hours"),
        title: String(localized: "Daily recap and standup notes"),
        symbol: "sun.max"),
      Milestone(
        badge: String(localized: "\(FeatureAccessRequirements.chatRequiredHours) hours"),
        title: String(localized: "Chat: ask anything about your day"),
        symbol: "bubble.left.and.bubble.right"),
      Milestone(
        badge: String(localized: "\(WeeklyAccessProgressSnapshot.recordedHourTarget) hours"),
        title: String(localized: "Weekly review"),
        symbol: "calendar"),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(milestones.enumerated()), id: \.offset) { index, milestone in
        HStack(spacing: 12) {
          Text(milestone.badge)
            .font(.custom("Figtree", size: 11))
            .fontWeight(.semibold)
            .foregroundColor(index == 0 ? theme.accentText : theme.textSecondary)
            .frame(width: 64, alignment: .trailing)

          ZStack {
            Circle()
              .fill(index == 0 ? theme.accent : theme.chipFill)
              .frame(width: 28, height: 28)
              .overlay(Circle().strokeBorder(theme.chipBorder, lineWidth: index == 0 ? 0 : 1))
            Image(systemName: milestone.symbol)
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(index == 0 ? .white : theme.textSecondary)
          }

          Text(milestone.title)
            .font(.custom("Figtree", size: 13))
            .fontWeight(index == 0 ? .semibold : .regular)
            .foregroundColor(theme.textPrimary)

          Spacer()
        }
        .frame(height: 28)

        if index < milestones.count - 1 {
          Rectangle()
            .fill(theme.chipBorder)
            .frame(width: 1.5, height: 16)
            .padding(.leading, 64 + 12 + 13)
        }
      }
    }
    .padding(.horizontal, 70)
  }
}

/// A macOS-style notification banner sliding in, which is exactly what the
/// person will see when their first cards are ready.
private struct TourNotificationIllustration: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isShown = false

  var body: some View {
    VStack {
      HStack {
        Spacer()
        banner
          .opacity(isShown ? 1 : 0)
          .offset(x: isShown ? 0 : 40)
      }
      Spacer()
    }
    .padding(22)
    .task {
      if reduceMotion {
        isShown = true
        return
      }
      try? await Task.sleep(for: .milliseconds(350))
      withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
        isShown = true
      }
    }
  }

  private var banner: some View {
    HStack(alignment: .top, spacing: 10) {
      Image("TargetFlowLogoMainApp")
        .resizable()
        .renderingMode(.original)
        .scaledToFit()
        .frame(width: 30, height: 30)

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("Target Flow")
            .font(.system(size: 12, weight: .semibold))
          Spacer()
          Text("now")
            .font(.system(size: 11))
            .foregroundColor(theme.textMuted)
        }
        Text("Your first Target Flow cards are ready")
          .font(.system(size: 12, weight: .semibold))
        Text("Take a look at what Target Flow picked up from your last few minutes of work.")
          .font(.system(size: 12))
          .foregroundColor(theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundColor(theme.textPrimary)
    }
    .padding(12)
    .frame(width: 330)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(theme.popoverBorder, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.14), radius: 16, x: 0, y: 8)
  }
}
