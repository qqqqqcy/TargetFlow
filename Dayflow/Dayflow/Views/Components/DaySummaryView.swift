//
//  DaySummaryView.swift
//  Dayflow
//
//  "Your day so far" dashboard showing category breakdown and focus stats
//

import SwiftUI

struct DaySummaryLoadToken: Equatable, Sendable {
  let id: UUID
  let dayString: String

  init(id: UUID = UUID(), dayString: String) {
    self.id = id
    self.dayString = dayString
  }

  /// Token equality is the latest-wins guarantee. The day keeps tokens self-describing and
  /// prevents a request identity from being reused across timeline days.
  func matches(latest: DaySummaryLoadToken?) -> Bool {
    self == latest
  }
}

struct DaySummaryView: View {
  @Environment(\.dayflowTheme) private var theme

  let selectedDate: Date
  let categories: [TimelineCategory]
  let storageManager: StorageManaging
  let recordingControlMode: RecordingControlMode

  @State private var timelineCards: [TimelineCard] = []
  @State private var isLoading = true
  @State private var hasCompletedInitialLoad = false
  @State private var focusCategoryIDs: Set<UUID> = []
  @State private var isEditingFocusCategories = false
  @State private var distractionCategoryIDs: Set<UUID> = []
  @State private var isEditingDistractionCategories = false
  @State private var dayGoalPlan: DayGoalPlan?

  // MARK: - Pre-computed Stats (to avoid expensive parsing during body evaluation)
  // These are computed on background thread when data loads, avoiding main thread hangs
  @State private var cardsWithDurations: [DaySummaryStats.CardWithDuration] = []
  @State private var cachedCategoryDurations: [CategoryTimeData] = []
  @State private var cachedTotalFocusTime: TimeInterval = 0
  @State private var cachedTotalCapturedTime: TimeInterval = 0
  @State private var cachedFocusBlocks: [FocusBlock] = []
  @State private var cachedTotalDistractedTime: TimeInterval = 0
  @State private var dataLoadTask: Task<Void, Never>?
  @State private var categoryStatsTask: Task<Void, Never>?
  @State private var dataLoadToken: DaySummaryLoadToken?
  @State private var categoryStatsToken: DaySummaryLoadToken?

  private enum Design {
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 48
    static let sectionSpacing: CGFloat = 26
    static let headerSpacing: CGFloat = 6
    static let donutSectionSpacing: CGFloat = 20

  }

  // MARK: - Computed Stats

  private var timelineDayInfo: (dayString: String, startOfDay: Date, endOfDay: Date) {
    let timelineDate = timelineDisplayDate(from: selectedDate)
    let info = timelineDate.getDayInfoFor4AMBoundary()
    return (info.dayString, info.startOfDay, info.endOfDay)
  }

  private var effectiveGoalPlan: DayGoalPlan {
    if let dayGoalPlan {
      return dayGoalPlan.carriedForward(to: timelineDayInfo.dayString, categories: categories)
    }
    return DayGoalPlan.defaultPlan(day: timelineDayInfo.dayString, categories: categories)
  }

  // MARK: - Cached Stats Accessors
  // These now return pre-computed values instead of computing during body evaluation

  private var categoryDurations: [CategoryTimeData] {
    cachedCategoryDurations
  }

  private var totalFocusTime: TimeInterval {
    cachedTotalFocusTime
  }

  private var totalCapturedTime: TimeInterval {
    cachedTotalCapturedTime
  }

  private var focusBlocks: [FocusBlock] {
    cachedFocusBlocks
  }

  private var totalDistractedTime: TimeInterval {
    cachedTotalDistractedTime
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Design.sectionSpacing) {
          daySoFarSection

          sectionDivider

          focusSection

          sectionDivider

          distractionsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Design.topPadding)
        .padding(.bottom, Design.bottomPadding)
        .padding(.horizontal, Design.horizontalPadding)
      }
      .scrollIndicators(.never)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      loadData()
    }
    .onDisappear {
      cancelLoadTasks()
    }
    .onChange(of: selectedDate) {
      loadData()
    }
    .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { notification in
      if let dayString = notification.userInfo?["dayString"] as? String {
        guard dayString == timelineDayInfo.dayString else { return }
      }
      loadData()
    }
    .onChange(of: categories) {
      loadData()
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if isEditingFocusCategories {
        isEditingFocusCategories = false
      }
      if isEditingDistractionCategories {
        isEditingDistractionCategories = false
      }
    }
  }

  // MARK: - Data Loading

  private func loadData() {
    dataLoadTask?.cancel()
    categoryStatsTask?.cancel()
    categoryStatsTask = nil
    categoryStatsToken = nil

    isLoading = true

    let dayInfo = timelineDayInfo
    let dayString = dayInfo.dayString
    let loadToken = DaySummaryLoadToken(dayString: dayString)
    dataLoadToken = loadToken
    let storageManager = storageManager

    // Capture current state for background computation
    let currentCategories = categories

    dataLoadTask = Task.detached(priority: .userInitiated) {
      // Use timeline display date to handle 4 AM boundary
      let cards = storageManager.fetchTimelineCards(forDay: dayString)
      let plan = DaySummaryStats.carriedForwardGoalPlan(
        day: dayString,
        storageManager: storageManager,
        categories: currentCategories
      )
      // Pre-compute all card durations (expensive parsing done once here, off main thread)
      let precomputed = DaySummaryStats.precomputeCardDurations(cards)

      // Pre-compute all stats using the parsed durations
      let catDurations = DaySummaryStats.computeCategoryDurations(
        from: precomputed, categories: currentCategories)
      let totalCaptured = DaySummaryStats.computeTotalCapturedTime(
        from: precomputed, categories: currentCategories)
      let totalFocus = DaySummaryStats.computeTotalFocusTime(
        from: precomputed, snapshots: plan.focusCategories, categories: currentCategories)
      let blocks = DaySummaryStats.computeFocusBlocks(
        from: precomputed, snapshots: plan.focusCategories, baseDate: dayInfo.startOfDay,
        categories: currentCategories)
      let totalDistracted = DaySummaryStats.computeTotalDistractedTime(
        from: precomputed, snapshots: plan.distractionCategories, categories: currentCategories)

      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard loadToken.matches(latest: self.dataLoadToken) else { return }

        // A targeted refresh may have started while this full load was running. The full load
        // owns the complete snapshot, so it also owns the overlapping stats fields.
        self.categoryStatsTask?.cancel()
        self.categoryStatsTask = nil
        self.categoryStatsToken = nil

        self.timelineCards = cards
        self.applyGoalPlan(plan)
        self.cardsWithDurations = precomputed
        self.cachedCategoryDurations = catDurations
        self.cachedTotalCapturedTime = totalCaptured
        self.cachedTotalFocusTime = totalFocus
        self.cachedFocusBlocks = blocks
        self.cachedTotalDistractedTime = totalDistracted
        self.isLoading = false
        self.hasCompletedInitialLoad = true
        self.dataLoadTask = nil
      }
    }
  }

  private func cancelLoadTasks() {
    dataLoadTask?.cancel()
    categoryStatsTask?.cancel()
    dataLoadTask = nil
    categoryStatsTask = nil
    dataLoadToken = nil
    categoryStatsToken = nil
  }

  // MARK: - Header

  private var daySoFarSection: some View {
    daySoFarContent
  }

  private var daySoFarContent: some View {
    VStack(alignment: .leading, spacing: Design.donutSectionSpacing) {
      VStack(alignment: .leading, spacing: Design.headerSpacing) {
        Text("Your day so far")
          .font(.system(size: 24, weight: .semibold))
          .foregroundColor(theme.textPrimary)
      }

      if isLoading && hasCompletedInitialLoad == false {
        ProgressView()
          .frame(width: 205, height: 205)
          .frame(maxWidth: .infinity)
      } else if !categoryDurations.isEmpty {
        CategoryDonutChart(data: categoryDurations, size: 205)
          .frame(maxWidth: .infinity)
      } else {
        emptyChartPlaceholder
          .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: - Empty State

  private var emptyChartPlaceholder: some View {
    VStack(spacing: 12) {
      Circle()
        .stroke(theme.targetsTrackFill, lineWidth: 20)
        .frame(width: 140, height: 140)

      Text("No activity data yet")
        .font(.system(size: 12))
        .foregroundColor(theme.textSecondary)
    }
    .padding(.vertical, 20)
  }

  // MARK: - Focus Section

  private var focusSection: some View {
    DayFocusSummarySection(
      totalFocusText: formatDurationTitleCase(totalFocusTime),
      focusBlocks: focusBlocks,
      isSelectionEmpty: isFocusSelectionEmpty,
      categories: selectableCategories,
      selectedCategoryIDs: focusCategoryIDs,
      isEditingCategories: isEditingFocusCategories,
      onEditCategories: {
        isEditingFocusCategories = true
        isEditingDistractionCategories = false
      },
      onToggleCategory: toggleFocusCategory,
      onDoneEditing: {
        isEditingFocusCategories = false
      }
    )
  }

  private var distractionsSection: some View {
    DayDistractionSummarySection(
      totalCapturedText: formatDurationLowercase(totalCapturedTime),
      totalDistractedText: formatDurationLowercase(totalDistractedTime),
      distractedRatio: distractedRatio,
      isSelectionEmpty: isDistractionSelectionEmpty,
      categories: selectableCategories,
      selectedCategoryIDs: distractionCategoryIDs,
      isEditingCategories: isEditingDistractionCategories,
      onEditCategories: {
        isEditingDistractionCategories = true
        isEditingFocusCategories = false
      },
      onToggleCategory: toggleDistractionCategory,
      onDoneEditing: {
        isEditingDistractionCategories = false
      }
    )
  }

  private var sectionDivider: some View {
    Rectangle()
      .fill(theme.rightPanelDivider)
      .frame(height: 1)
      .frame(maxWidth: .infinity)
  }

  private var distractedRatio: Double {
    let captured = totalCapturedTime
    guard captured > 0 else { return 0 }
    let ratio = totalDistractedTime / captured
    return min(max(ratio, 0), 1)
  }

  // MARK: - Helpers

  nonisolated private func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var selectableCategories: [TimelineCategory] {
    categories
      .filter {
        $0.isSystem == false && $0.isIdle == false && normalizedCategoryName($0.name) != "system"
      }
      .sorted { $0.order < $1.order }
  }

  private var isFocusSelectionEmpty: Bool {
    focusCategoryIDs.isEmpty
  }

  private var isDistractionSelectionEmpty: Bool {
    distractionCategoryIDs.isEmpty
  }

  private func toggleFocusCategory(_ category: TimelineCategory) {
    var plan = effectiveGoalPlan
    let categoryID = category.id.uuidString
    if plan.focusCategories.contains(where: { $0.categoryID == categoryID }) {
      plan.focusCategories.removeAll { $0.categoryID == categoryID }
    } else {
      plan.focusCategories.append(
        DayGoalCategorySnapshot(category: category, sortOrder: plan.focusCategories.count)
      )
    }
    saveGoalPlan(plan)
  }

  private func toggleDistractionCategory(_ category: TimelineCategory) {
    var plan = effectiveGoalPlan
    let categoryID = category.id.uuidString
    if plan.distractionCategories.contains(where: { $0.categoryID == categoryID }) {
      plan.distractionCategories.removeAll { $0.categoryID == categoryID }
    } else {
      plan.distractionCategories.append(
        DayGoalCategorySnapshot(category: category, sortOrder: plan.distractionCategories.count)
      )
    }
    saveGoalPlan(plan)
  }

  private func applyGoalPlan(_ plan: DayGoalPlan) {
    let resolved = plan.carriedForward(to: timelineDayInfo.dayString, categories: categories)
    dayGoalPlan = resolved
    focusCategoryIDs = Set(resolved.focusCategories.compactMap { UUID(uuidString: $0.categoryID) })
    distractionCategoryIDs = Set(
      resolved.distractionCategories.compactMap { UUID(uuidString: $0.categoryID) }
    )
  }

  private func saveGoalPlan(_ plan: DayGoalPlan) {
    let normalized = normalizedPlan(plan)
    applyGoalPlan(normalized)
    recomputeCachedStatsForCategoryChange()

    let storageManager = storageManager
    Task.detached(priority: .utility) {
      storageManager.saveDayGoalPlan(normalized)
    }
  }

  private func normalizedPlan(_ plan: DayGoalPlan) -> DayGoalPlan {
    var copy = plan.carriedForward(to: timelineDayInfo.dayString, categories: selectableCategories)
    copy.focusCategories = copy.focusCategories.enumerated().map { index, snapshot in
      let resolved = resolveSnapshot(snapshot)
      return DayGoalCategorySnapshot(
        categoryID: resolved.categoryID,
        name: resolved.name,
        colorHex: resolved.colorHex,
        sortOrder: index
      )
    }
    copy.distractionCategories = copy.distractionCategories.enumerated().map { index, snapshot in
      let resolved = resolveSnapshot(snapshot)
      return DayGoalCategorySnapshot(
        categoryID: resolved.categoryID,
        name: resolved.name,
        colorHex: resolved.colorHex,
        sortOrder: index
      )
    }
    return copy
  }

  private func resolveSnapshot(_ snapshot: DayGoalCategorySnapshot) -> DayGoalCategorySnapshot {
    let current =
      selectableCategories.first(where: { $0.id.uuidString == snapshot.categoryID })
      ?? selectableCategories.first {
        normalizedCategoryName($0.name) == normalizedCategoryName(snapshot.name)
      }
    guard let current else {
      return snapshot
    }
    return DayGoalCategorySnapshot(
      categoryID: current.id.uuidString,
      name: current.name,
      colorHex: current.colorHex,
      sortOrder: snapshot.sortOrder
    )
  }

  private func formatDurationTitleCase(_ seconds: TimeInterval) -> String {
    LocalizedDuration.string(seconds)
  }

  private func formatDurationLowercase(_ seconds: TimeInterval) -> String {
    LocalizedDuration.string(seconds)
  }

  /// Recomputes cached stats when categories change (rename/color/system/focus/distraction flags)
  private func recomputeCachedStatsForCategoryChange() {
    categoryStatsTask?.cancel()

    let precomputed =
      cardsWithDurations.isEmpty
      ? DaySummaryStats.precomputeCardDurations(timelineCards) : cardsWithDurations
    let currentCategories = categories
    let plan = effectiveGoalPlan
    let dayInfo = timelineDayInfo
    let baseDate = dayInfo.startOfDay
    let loadToken = DaySummaryLoadToken(dayString: dayInfo.dayString)
    categoryStatsToken = loadToken

    categoryStatsTask = Task.detached(priority: .userInitiated) {
      let catDurations = DaySummaryStats.computeCategoryDurations(
        from: precomputed, categories: currentCategories)
      let totalCaptured = DaySummaryStats.computeTotalCapturedTime(
        from: precomputed, categories: currentCategories)
      let totalFocus = DaySummaryStats.computeTotalFocusTime(
        from: precomputed, snapshots: plan.focusCategories, categories: currentCategories)
      let blocks = DaySummaryStats.computeFocusBlocks(
        from: precomputed, snapshots: plan.focusCategories, baseDate: baseDate,
        categories: currentCategories)
      let totalDistracted = DaySummaryStats.computeTotalDistractedTime(
        from: precomputed, snapshots: plan.distractionCategories, categories: currentCategories)

      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard loadToken.matches(latest: self.categoryStatsToken) else { return }

        self.cachedCategoryDurations = catDurations
        self.cachedTotalCapturedTime = totalCaptured
        self.cachedTotalFocusTime = totalFocus
        self.cachedFocusBlocks = blocks
        self.cachedTotalDistractedTime = totalDistracted
        self.categoryStatsTask = nil
      }
    }
  }
}

#Preview("Day Summary") {
  let sampleCategories: [TimelineCategory] = [
    TimelineCategory(name: "Research", colorHex: "#8BAAFF", order: 0),
    TimelineCategory(name: "Coding", colorHex: "#CF8FFF", order: 1),
    TimelineCategory(name: "Code review", colorHex: "#90DDF0", order: 2),
    TimelineCategory(name: "Debugging", colorHex: "#6E66D4", order: 3),
    TimelineCategory(name: "Distraction", colorHex: "#FF5950", order: 4),
    TimelineCategory(name: "Idle", colorHex: "#A0AEC0", order: 5, isSystem: true, isIdle: true),
  ]

  DaySummaryView(
    selectedDate: Date(),
    categories: sampleCategories,
    storageManager: StorageManager.shared,
    recordingControlMode: .active
  )
  .frame(width: 358, height: 700)
  .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
