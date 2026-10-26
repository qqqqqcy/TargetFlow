//
//  GettingStartedChecklistCard.swift
//  Dayflow
//
//  "Your first day" checklist that sits above the day summary on the
//  timeline for the first week after onboarding. Every item checks itself
//  off from real state (batches analyzed, card opened, notifications on),
//  so it doubles as a live progress view while the first cards are made.
//

import AppKit
import SwiftUI

struct GettingStartedChecklistCard: View {
  @Environment(\.dayflowTheme) private var theme
  @EnvironmentObject private var appState: AppState

  @AppStorage(GettingStarted.Keys.isActive) private var isActive = false
  @AppStorage(GettingStarted.Keys.checklistDismissed) private var isDismissed = false
  @AppStorage(GettingStarted.Keys.checklistCollapsed) private var isCollapsed = false
  @AppStorage(GettingStarted.Keys.openedCard) private var hasOpenedCard = false
  @AppStorage(GettingStarted.Keys.firstCardsReady) private var firstCardsFlag = false

  @State private var completedBatchCount = 0
  @State private var notificationsEnabled = false

  var body: some View {
    if isActive && !isDismissed && !GettingStarted.isChecklistExpired {
      card
        .padding(.top, 14)
        .padding(.horizontal, 18)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { _ in
          refresh()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
          refresh()
        }
    }
  }

  // MARK: - Derived state

  /// Set only by a batch that produced cards; idle batches don't count.
  private var hasFirstCards: Bool {
    firstCardsFlag
  }

  private var completedSteps: [Bool] {
    [hasFirstCards, hasOpenedCard, notificationsEnabled]
  }

  private var completedStepCount: Int {
    completedSteps.filter { $0 }.count
  }

  private var isAllDone: Bool {
    completedStepCount == completedSteps.count
  }

  // MARK: - Layout

  private var card: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      if !isCollapsed {
        VStack(alignment: .leading, spacing: 2) {
          if isAllDone {
            allDoneRow
          } else {
            firstCardsRow
            openCardRow
            notificationsRow
          }
        }
        .padding(.top, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(14)
    .background(theme.summaryCardFill)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      InnerGlow(
        shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
        color: theme.summaryCardInnerGlow, radius: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.summaryCardBorder, lineWidth: 1)
    )
    .shadow(color: theme.summaryCardShadow, radius: 4, x: 0, y: 1)
    .animation(.spring(response: 0.32, dampingFraction: 0.88), value: isCollapsed)
    .animation(.spring(response: 0.32, dampingFraction: 0.88), value: completedStepCount)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Your first day with Target Flow")
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
          .foregroundColor(theme.textPrimary)

        Spacer()

        Text("\(completedStepCount) of \(completedSteps.count)")
          .font(.custom("Figtree", size: 11))
          .fontWeight(.medium)
          .foregroundColor(theme.textTertiary)
          .monospacedDigit()

        iconButton(symbol: isCollapsed ? "chevron.down" : "chevron.up") {
          isCollapsed.toggle()
        }

        iconButton(symbol: "xmark") {
          AnalyticsService.shared.capture(
            "getting_started_checklist_dismissed",
            ["completed_steps": completedStepCount, "all_done": isAllDone])
          withAnimation(.easeOut(duration: 0.2)) {
            isDismissed = true
          }
        }
      }

      progressBar
    }
  }

  private var progressBar: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(theme.targetsTrackFill)
        Capsule()
          .fill(theme.accent)
          .frame(
            width: proxy.size.width * CGFloat(completedStepCount)
              / CGFloat(completedSteps.count))
      }
    }
    .frame(height: 4)
  }

  // MARK: - Rows

  private var firstCardsRow: some View {
    let subtitle: String
    if hasFirstCards {
      subtitle = String(localized: "Target Flow is turning your screen time into cards")
    } else if appState.isRecording {
      subtitle = String(localized: "Usually ready about 15 minutes after recording starts")
    } else {
      subtitle = String(localized: "Recording is paused. Turn it on to get your first cards.")
    }

    return ChecklistRow(
      status: hasFirstCards ? .done : (appState.isRecording ? .working : .todo),
      title: String(localized: "First cards on your timeline"),
      subtitle: subtitle
    )
  }

  private var openCardRow: some View {
    ChecklistRow(
      status: hasOpenedCard ? .done : .todo,
      title: String(localized: "Open a card"),
      subtitle: String(localized: "Click any card to see its summary and timelapse")
    )
  }

  private var notificationsRow: some View {
    ChecklistRow(
      status: notificationsEnabled ? .done : .todo,
      title: String(localized: "Turn on notifications"),
      subtitle: String(localized: "Hear when your first timeline cards are ready")
    ) {
      if !notificationsEnabled {
        rowButton(title: String(localized: "Turn on"), action: enableNotifications)
      }
    }
  }

  private var allDoneRow: some View {
    ChecklistRow(
      status: .done,
      title: String(localized: "You're all set"),
      subtitle: String(localized: "You've unlocked everything Target Flow does. Enjoy your timeline.")
    ) {
      rowButton(title: String(localized: "Done")) {
        AnalyticsService.shared.capture(
          "getting_started_checklist_dismissed",
          ["completed_steps": completedStepCount, "all_done": true])
        withAnimation(.easeOut(duration: 0.2)) {
          isDismissed = true
        }
      }
    }
  }

  // MARK: - Small controls

  private func iconButton(symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(theme.textMuted)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  private func rowButton(title: String, action: @escaping () -> Void) -> some View {
    DayflowSurfaceButton(
      action: action,
      content: {
        Text(title)
          .font(.custom("Figtree", size: 11))
          .fontWeight(.semibold)
      },
      background: theme.secondaryButtonFill,
      foreground: theme.secondaryButtonText,
      borderColor: theme.secondaryButtonBorder,
      cornerRadius: 999,
      horizontalPadding: 10,
      verticalPadding: 4,
      showShadow: false
    )
  }

  // MARK: - Actions

  private func refresh() {
    completedBatchCount = FeatureAccessRequirements.completedBatchCount()
    Task {
      let status = await NotificationService.shared.authorizationStatus()
      notificationsEnabled = status == .authorized || status == .provisional
    }
  }

  private func enableNotifications() {
    AnalyticsService.shared.capture("getting_started_checklist_notifications_tapped")
    Task {
      let status = await NotificationService.shared.authorizationStatus()
      if status == .notDetermined {
        notificationsEnabled = await NotificationService.shared.requestPermission()
      } else if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications")
      {
        // Already denied once; macOS only lets people turn it back on in System Settings.
        NSWorkspace.shared.open(url)
      }
    }
  }
}

// MARK: - Row

extension ChecklistRow where Trailing == EmptyView {
  init(status: ChecklistStatus, title: String, subtitle: String) {
    self.init(status: status, title: title, subtitle: subtitle) { EmptyView() }
  }
}

private enum ChecklistStatus: Equatable {
  case todo
  case working
  case progress(Double)
  case done
}

private struct ChecklistRow<Trailing: View>: View {
  @Environment(\.dayflowTheme) private var theme

  let status: ChecklistStatus
  let title: String
  let subtitle: String
  let trailing: () -> Trailing

  init(
    status: ChecklistStatus,
    title: String,
    subtitle: String,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.status = status
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      statusIcon
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.custom("Figtree", size: 12.5))
          .fontWeight(.semibold)
          .foregroundColor(status == .done ? theme.textTertiary : theme.textPrimary)
        Text(subtitle)
          .font(.custom("Figtree", size: 11))
          .foregroundColor(theme.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 6)

      trailing()
    }
    .padding(.vertical, 5)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch status {
    case .done:
      ZStack {
        Circle().fill(theme.accent)
        Image(systemName: "checkmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundColor(.white)
      }
      .transition(.scale.combined(with: .opacity))
    case .working:
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.75)
    case .progress(let value):
      ZStack {
        Circle()
          .stroke(theme.targetsTrackFill, lineWidth: 2.5)
        Circle()
          .trim(from: 0, to: max(value, 0.02))
          .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      .padding(1.5)
    case .todo:
      Circle()
        .strokeBorder(theme.textMuted.opacity(0.6), lineWidth: 1.5)
    }
  }
}
