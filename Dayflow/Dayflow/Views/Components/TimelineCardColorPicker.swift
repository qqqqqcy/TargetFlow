import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ColorOrganizerRoot: View {
  enum PresentationStyle {
    case embedded
    case sheet
  }

  enum FlowMode {
    case detailsAndColors
    case colorsOnly
  }

  var presentationStyle: PresentationStyle = .embedded
  var flowMode: FlowMode = .detailsAndColors
  var onBack: (() -> Void)?
  var onDismiss: (() -> Void)?
  var completionButtonTitle: String?
  var showsTitles: Bool = true
  var analyticsSurface: String? = nil
  @EnvironmentObject private var categoryStore: CategoryStore
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum CategorySetupStage: String, Hashable {
    case details
    case colors
  }

  @State private var stage: CategorySetupStage
  @State private var editingCategoryID: UUID?
  @State private var draftName: String = ""
  @State private var draftDetails: String = ""
  @State private var numPoints: Int = 3
  @State private var normalizedRadius: Double = 0.7
  @State private var currentAngle: Double = -Double.pi / 2
  @State private var isDraggingColor: Bool = false
  @State private var showFirstTimeHints: Bool = !UserDefaults.standard.bool(
    forKey: CategoryStore.StoreKeys.hasUsedApp)
  @State private var pendingScrollTarget: UUID? = nil
  @State private var isAddButtonHovered: Bool = false
  @State private var trackedStages: Set<CategorySetupStage> = []
  @State private var addCount = 0
  @State private var deleteCount = 0
  @State private var renameCount = 0
  @State private var detailsUpdateCount = 0
  @State private var colorChangeCount = 0
  @State private var didAdjustPalette = false

  init(
    presentationStyle: PresentationStyle = .embedded,
    flowMode: FlowMode = .detailsAndColors,
    onBack: (() -> Void)? = nil,
    onDismiss: (() -> Void)? = nil,
    completionButtonTitle: String? = nil,
    showsTitles: Bool = true,
    analyticsSurface: String? = nil
  ) {
    self.presentationStyle = presentationStyle
    self.flowMode = flowMode
    self.onBack = onBack
    self.onDismiss = onDismiss
    self.completionButtonTitle = completionButtonTitle
    self.showsTitles = showsTitles
    self.analyticsSurface = analyticsSurface
    _stage = State(initialValue: flowMode == .colorsOnly ? .colors : .details)
  }

  private var categories: [TimelineCategory] {
    categoryStore.editableCategories
  }

  private var isOnboardingAnalyticsEnabled: Bool {
    analyticsSurface == "onboarding"
  }

  private var onboardingRole: String {
    UserDefaults.standard.string(forKey: CategoryStore.StoreKeys.onboardingSelectedRole)
      ?? "unknown"
  }

  private var onboardingPreset: String {
    UserDefaults.standard.string(forKey: CategoryStore.StoreKeys.onboardingAppliedCategoryPreset)
      ?? "unknown"
  }

  private var supportsDetailsStage: Bool {
    flowMode == .detailsAndColors
  }

  private var spectrumColors: [String] {
    (0..<8).map { i in
      let angleOffset = Double(i) * (.pi * 2) / 8.0
      let angle = currentAngle + angleOffset
      let hue = angle * 180.0 / .pi
      let lightness = 15 + 75 * normalizedRadius
      return hslToHex(hue, 100, lightness)
    }
  }

  var body: some View {
    ZStack {
      backgroundView
      contentCard
    }
    .overlay(alignment: .bottomTrailing) {
      if presentationStyle == .embedded {
        bottomButtonBar
          .padding(.trailing, 40)
          .padding(.bottom, 32)
      }
    }
    .onAppear {
      trackStageViewIfNeeded(stage)
    }
    .onChange(of: stage) { _, newStage in
      trackStageViewIfNeeded(newStage)
    }
    .onDisappear {
      commitPendingEditsIfNeeded()
    }
  }

  private var contentCard: some View {
    GeometryReader { proxy in
      let isCompact = proxy.size.width < 960
      let sideBySide = proxy.size.width >= 720

      VStack(spacing: 0) {
        if showsTitles {
          HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
              Text(stage == .details ? String(localized: "Events and Goals") : String(localized: "Event colors"))
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
              Text(stage == .details ? String(localized: "Manage events and choose the goals you want to work on now.") : String(localized: "Use colors to identify events. Colors do not affect goal evaluation."))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
            if presentationStyle == .sheet {
              Button {
                commitPendingEditsIfNeeded()
                categoryStore.persist()
                onDismiss?()
              } label: {
                Image(systemName: "xmark")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(theme.textTertiary)
                  .frame(width: DayflowLayout.buttonHeight, height: DayflowLayout.buttonHeight)
                  .background(
                    theme.panelSolid,
                    in: RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius))
              }
              .buttonStyle(.plain)
              .pointingHandCursor()
              .accessibilityLabel("Close Events and Goals")
            }
          }
          .padding(24)
          Rectangle().fill(theme.rightPanelDivider).frame(height: 1)
        }

        ScrollView {
          ZStack(alignment: .topLeading) {
            Group {
              if stage == .details {
                if sideBySide {
                  HStack(alignment: .top, spacing: 28) {
                    instructionsPanel(isCompact: isCompact, showTitles: showsTitles)
                      .frame(width: isCompact ? 210 : 240, alignment: .leading)
                    categoryEditorPanel(isCompact: isCompact)
                  }
                } else {
                  VStack(alignment: .leading, spacing: 20) {
                    instructionsPanel(isCompact: true, showTitles: showsTitles)
                    categoryEditorPanel(isCompact: true)
                  }
                }
              } else {
                if sideBySide {
                  HStack(alignment: .top, spacing: 28) {
                    colorPickerPanel(isCompact: isCompact, showTitles: showsTitles)
                      .frame(width: 240, alignment: .leading)
                    colorAssignmentPanel(isCompact: isCompact)
                  }
                } else {
                  VStack(alignment: .leading, spacing: 20) {
                    colorPickerPanel(isCompact: true, showTitles: showsTitles)
                    colorAssignmentPanel(isCompact: true)
                  }
                }
              }
            }
            .id(stage)
            .transition(DayflowMotion.transition(reduceMotion: reduceMotion))
          }
          .padding(24)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .animation(reduceMotion ? .easeOut(duration: 0.12) : DayflowMotion.content, value: stage)
        }

        if presentationStyle == .sheet {
          Rectangle().fill(theme.rightPanelDivider).frame(height: 1)
          bottomButtonBar.padding(.horizontal, 24).padding(.vertical, 16)
        }
      }
      .frame(maxWidth: 980)
      .frame(height: max(240, min(proxy.size.height - 48, 680)))
      .background(
        RoundedRectangle(cornerRadius: 18)
          .fill(theme.rightPanelFill)
          .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.rightPanelBorder, lineWidth: 1))
          .shadow(color: theme.panelShadow, radius: 22, x: 0, y: 8)
      )
      .padding(.horizontal, isCompact ? 20 : 40)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  private func instructionsPanel(isCompact: Bool, showTitles: Bool) -> some View {
    VStack(alignment: .leading, spacing: showTitles ? 20 : 16) {
      if showTitles {
        VStack(alignment: .leading, spacing: 6) {
          Text(presentationStyle == .sheet ? String(localized: "You can select multiple current goals") : String(localized: "Part 1 of 2"))
            .font(Font.system(size: 14).weight(.bold))
            .foregroundColor(
              theme.accent
            )
            .frame(maxWidth: .infinity, alignment: .leading)

          Text("Describe your events")
            .font(
              Font.system(size: 20, weight: .semibold)
            )
            .foregroundColor(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      VStack(alignment: .leading, spacing: 16) {
        instructionRow(
          icon: "CategoriesOrganize",
          text:
            String(
              localized:
                "Write down what you want to do and add details, such as fixing a login issue or preparing for an interview."
            )
        )
        .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)

        instructionRow(
          icon: "CategoriesTextSelect",
          text:
            String(
              localized:
                "Turn on “Current goal” below each event. You can select multiple goals. Working on any of them counts as focused."
            )
        )
        .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)
      }

      Text(
        "You will receive reminders for neutral or distracting events, and none while focused. Turn off all goals to pause goal evaluation."
      )
      .font(Font.system(size: 12).weight(.medium))
      .foregroundColor(
        theme.textSecondary
      )
      .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)
    }
  }

  private func instructionRow(icon: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon == "CategoriesOrganize" ? "text.alignleft" : "checkmark.circle")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(theme.accent)
        .frame(width: 28, height: 28)
        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

      Text(text)
        .font(Font.system(size: 14).weight(.medium))
        .foregroundColor(theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func colorPickerPanel(isCompact: Bool, showTitles: Bool) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      if showTitles {
        VStack(alignment: .leading, spacing: 6) {
          Text("Visual cues")
            .font(Font.system(size: 14).weight(.bold))
            .foregroundColor(
              theme.accent
            )
            .frame(maxWidth: .infinity, alignment: .leading)

          Text("Edit colors")
            .font(
              Font.system(size: 20, weight: .semibold)
            )
            .foregroundColor(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      VStack(spacing: 12) {
        ZStack {
          DotPattern(width: 10, height: 10)
            .frame(width: 224, height: 224)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)

          ColorPickerView(
            size: 224,
            padding: 20,
            bulletRadius: 24,
            spreadFactor: 0.4,
            minSpread: .pi / 1.5,
            maxSpread: .pi / 3,
            minLight: 15,
            maxLight: 90,
            showColorWheel: false,
            numPoints: numPoints,
            onColorChange: { _ in },
            onRadiusChange: { updatePaletteRadius($0) },
            onAngleChange: { updatePaletteAngle($0) }
          )
        }
        .frame(width: 224, height: 224)

      }

      VStack(alignment: .leading, spacing: 12) {
        Text(
          isDraggingColor
            ? String(localized: "Drag onto an event →")
            : String(
              localized:
                "Drag the color wheel above to adjust the palette, then drag colors onto events. Colors are only used as visual cues."
            )
        )
        .font(Font.system(size: 13).weight(.medium))
        .foregroundColor(
          theme.textSecondary)

        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8
        ) {
          ForEach(Array(spectrumColors.enumerated()), id: \.offset) { index, hex in
            ColorSwatch(
              hex: hex,
              showHint: showFirstTimeHints && index == 0,
              onDragStart: {
                isDraggingColor = true
                showFirstTimeHints = false
              }
            )
          }
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
          isDraggingColor = false
          return false
        }
      }
    }
  }

  private var canAddMoreCategories: Bool {
    categories.count < 20
  }

  private var addCategoryButton: some View {
    SettingsSecondaryButton(
      title: String(localized: "Add event"), systemImage: "plus", isDisabled: !canAddMoreCategories
    ) {
      createNewCategory()
    }
    .scaleEffect(isAddButtonHovered ? 1.02 : 1.0)
    .animation(.easeOut(duration: 0.18), value: isAddButtonHovered)
    .shadow(
      color: theme.isDark ? Color.black.opacity(isAddButtonHovered ? 0.18 : 0.1) : .clear,
      radius: isAddButtonHovered ? 6 : 3, x: 0, y: isAddButtonHovered ? 3 : 1
    )
    .onHover { hovering in
      if canAddMoreCategories {
        isAddButtonHovered = hovering
      } else {
        isAddButtonHovered = false
      }
    }
    .pointingHandCursor(enabled: canAddMoreCategories)
  }

  private func colorAssignmentPanel(isCompact: Bool) -> some View {
    let containerHeight: CGFloat = (isCompact ? 404 : 494) * 0.75

    return VStack(alignment: .leading, spacing: 16) {
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 16)
          .fill(
            theme.panelSolid
          )
          .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

        RoundedRectangle(cornerRadius: 16)
          .stroke(
            theme.rightPanelBorder,
            lineWidth: theme.isDark ? 0.75 : 1
          )
          .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

        ScrollView(showsIndicators: false) {
          VStack(spacing: 8) {
            ForEach(categories) { category in
              ColorAssignmentCard(
                category: category,
                showDetails: supportsDetailsStage,
                onColorDrop: { hex in
                  assignColor(hex, to: category)
                  isDraggingColor = false
                }
              )
            }
          }
          .padding(.horizontal, 16)
          .padding(.top, 16)
          .padding(.bottom, 24)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .frame(maxWidth: isCompact ? .infinity : 708)
      .frame(height: containerHeight, alignment: .topLeading)

      Text("Colors are optional and can be changed at any time.")
        .font(Font.system(size: 12).weight(.medium))
        .foregroundColor(
          theme.textSecondary
        )
        .frame(maxWidth: .infinity, alignment: .leading)

    }
    .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
  }

  private var bottomButtonBar: some View {
    HStack(spacing: 16) {
      if presentationStyle == .sheet && stage == .details {
        addCategoryButton
      }
      Spacer(minLength: 12)

      if stage == .details {
        if supportsDetailsStage == false, let onBack {
          SettingsSecondaryButton(title: String(localized: "Back")) {
            commitPendingEditsIfNeeded()
            onBack()
          }
        }

        if presentationStyle == .sheet {
          SettingsSecondaryButton(title: String(localized: "Adjust colors")) {
            commitPendingEditsIfNeeded()
            withAnimation(.easeInOut(duration: 0.25)) { stage = .colors }
          }
          SettingsPrimaryButton(title: completionButtonTitle ?? String(localized: "Done")) {
            commitPendingEditsIfNeeded()
            categoryStore.persist()
            onDismiss?()
          }
        } else {
          SettingsPrimaryButton(
            title: String(localized: "Next"), systemImage: "chevron.right",
            isDisabled: categories.isEmpty
          ) {
            commitPendingEditsIfNeeded()
            trackDetailsCompletion()
            categoryStore.persist()
            withAnimation(.easeInOut(duration: 0.25)) {
              stage = .colors
            }
          }
        }
      } else {
        SettingsSecondaryButton(title: String(localized: "Back")) {
          if supportsDetailsStage {
            withAnimation(.easeInOut(duration: 0.25)) {
              isDraggingColor = false
              stage = .details
            }
          } else {
            onBack?()
          }
        }

        SettingsPrimaryButton(
          title: completionButtonTitle ?? String(localized: "Next"), systemImage: "chevron.right",
          isDisabled: categories.isEmpty
        ) {
          trackColorsCompletion()
          categoryStore.persist()
          onDismiss?()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private func categoryEditorPanel(isCompact: Bool) -> some View {
    let containerHeight: CGFloat = (isCompact ? 404 : 494) * 0.75

    return ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: 24) {
        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: 16)
            .fill(
              theme.panelSolid
            )
            .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

          RoundedRectangle(cornerRadius: 16)
            .stroke(
              theme.rightPanelBorder,
              lineWidth: theme.isDark ? 0.75 : 1
            )
            .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

          ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
              if categories.isEmpty {
                emptyState
              } else {
                ForEach(categories) { category in
                  EditableCategoryCard(
                    category: category,
                    isEditing: editingCategoryID == category.id,
                    draftName: editingCategoryID == category.id
                      ? $draftName : .constant(category.name),
                    draftDetails: editingCategoryID == category.id
                      ? $draftDetails : .constant(category.details),
                    onStartEdit: { startEditing(category) },
                    onSave: { saveEdits(for: category) },
                    onDelete: { deleteCategory(category) }
                  )
                  .id(category.id)
                }
              }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 16)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxWidth: isCompact ? .infinity : 708)
        .frame(height: containerHeight, alignment: .topLeading)
        .onChange(of: pendingScrollTarget) { _, target in
          guard let target else { return }
          withAnimation(.easeOut(duration: 0.35)) {
            proxy.scrollTo(target, anchor: .bottom)
          }
          DispatchQueue.main.async { pendingScrollTarget = nil }
        }

        if presentationStyle == .embedded {
          addCategoryButton
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
    }
  }

  private var emptyState: some View {
    Text("Add something you want to do.")
      .font(Font.system(size: 13).weight(.medium))
      .foregroundColor(
        theme.textSecondary
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            theme.rightPanelBorder,
            lineWidth: 0.5)
      )
  }

  @ViewBuilder
  private var backgroundView: some View {
    switch presentationStyle {
    case .embedded:
      Color.clear
    case .sheet:
      theme.sheetOverlay
        .ignoresSafeArea()
    }
  }

  private func createNewCategory() {
    guard canAddMoreCategories else { return }

    withAnimation(.easeInOut(duration: 0.25)) {
      if stage != .details {
        stage = .details
      }

      showFirstTimeHints = false

      let baseName = String(localized: "New event")
      var candidate = baseName
      var suffix = 2
      let existingNames = Set(categories.map { $0.name.lowercased() })
      while existingNames.contains(candidate.lowercased()) {
        candidate = "\(baseName) \(suffix)"
        suffix += 1
      }

      categoryStore.markOnboardingCategoriesCustomized()
      categoryStore.addCategory(name: candidate)
      addCount += 1
      captureOnboardingEvent(
        "onboarding_category_added",
        [
          "category_name": candidate,
          "total_count": categoryStore.editableCategories.count,
          "stage": CategorySetupStage.details.rawValue,
        ])
      let editable = categoryStore.editableCategories
      if let newlyCreated = editable.last {
        editingCategoryID = newlyCreated.id
        draftName = newlyCreated.name
        draftDetails = newlyCreated.details

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          pendingScrollTarget = newlyCreated.id
        }
      }
    }
  }

  private func startEditing(_ category: TimelineCategory) {
    if editingCategoryID != nil && editingCategoryID != category.id {
      commitPendingEditsIfNeeded()
    }
    withAnimation(.easeInOut(duration: 0.2)) {
      editingCategoryID = category.id
      draftName = category.name
      draftDetails = category.details
    }
  }

  private func saveEdits(for category: TimelineCategory) {
    let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    let didRename = !trimmedName.isEmpty && trimmedName != category.name
    let didUpdateDetails = draftDetails != category.details
    let previousName = category.name
    let previousDetails = category.details

    if didRename || didUpdateDetails {
      categoryStore.markOnboardingCategoriesCustomized()
    }

    if didRename {
      categoryStore.renameCategory(id: category.id, to: trimmedName)
      renameCount += 1
      captureOnboardingEvent(
        "onboarding_category_renamed",
        [
          "category_name": trimmedName,
          "previous_name": previousName,
          "stage": CategorySetupStage.details.rawValue,
        ])
    }
    categoryStore.updateDetails(draftDetails, for: category.id)
    if didUpdateDetails {
      detailsUpdateCount += 1
      captureOnboardingEvent(
        "onboarding_category_details_updated",
        [
          "category_name": didRename ? trimmedName : previousName,
          "details_length": draftDetails.count,
          "had_previous_details": previousDetails.isEmpty == false,
          "stage": CategorySetupStage.details.rawValue,
        ])
    }
    endEditing()
  }

  private func deleteCategory(_ category: TimelineCategory) {
    withAnimation(.easeInOut(duration: 0.2)) {
      if editingCategoryID == category.id {
        endEditing()
      }
      categoryStore.markOnboardingCategoriesCustomized()
      categoryStore.removeCategory(id: category.id)
      deleteCount += 1
      captureOnboardingEvent(
        "onboarding_category_deleted",
        [
          "category_name": category.name,
          "remaining_count": categoryStore.editableCategories.count,
          "stage": stage.rawValue,
        ])
    }
  }

  private func assignColor(_ hex: String, to category: TimelineCategory) {
    let previousHex = category.colorHex
    categoryStore.markOnboardingCategoriesCustomized()
    categoryStore.assignColor(hex, to: category.id)

    guard hex != previousHex else { return }

    colorChangeCount += 1
    captureOnboardingEvent(
      "onboarding_category_color_changed",
      [
        "category_name": category.name,
        "color_hex": hex,
        "previous_color_hex": previousHex,
        "stage": CategorySetupStage.colors.rawValue,
      ])
  }

  private func updatePaletteRadius(_ newRadius: Double) {
    if abs(newRadius - normalizedRadius) > 0.0001 {
      didAdjustPalette = true
    }
    normalizedRadius = newRadius
  }

  private func updatePaletteAngle(_ newAngle: Double) {
    if abs(newAngle - currentAngle) > 0.0001 {
      didAdjustPalette = true
    }
    currentAngle = newAngle
  }

  private func trackStageViewIfNeeded(_ stage: CategorySetupStage) {
    guard isOnboardingAnalyticsEnabled else { return }
    guard trackedStages.contains(stage) == false else { return }

    trackedStages.insert(stage)
    AnalyticsService.shared.screen("onboarding_categories_\(stage.rawValue)")
  }

  private func trackDetailsCompletion() {
    captureOnboardingEvent(
      "onboarding_categories_details_completed",
      [
        "stage": CategorySetupStage.details.rawValue,
        "added_count": addCount,
        "renamed_count": renameCount,
        "details_updated_count": detailsUpdateCount,
        "deleted_count": deleteCount,
      ])
  }

  private func trackColorsCompletion() {
    captureOnboardingEvent(
      "onboarding_categories_colors_completed",
      [
        "stage": CategorySetupStage.colors.rawValue,
        "added_count": addCount,
        "renamed_count": renameCount,
        "details_updated_count": detailsUpdateCount,
        "deleted_count": deleteCount,
        "color_changed_count": colorChangeCount,
        "did_adjust_palette": didAdjustPalette,
        "palette_radius": normalizedRadius,
        "palette_angle": currentAngle,
      ])
  }

  private func captureOnboardingEvent(_ name: String, _ extra: [String: Any]) {
    guard isOnboardingAnalyticsEnabled else { return }

    var payload: [String: Any] = [
      "surface": analyticsSurface ?? "unknown",
      "role": onboardingRole,
      "preset": onboardingPreset,
      "category_count": categories.count,
    ]

    extra.forEach { key, value in
      payload[key] = value
    }

    AnalyticsService.shared.capture(name, payload)
  }

  private func commitPendingEditsIfNeeded() {
    guard let editingID = editingCategoryID,
      let category = categories.first(where: { $0.id == editingID })
    else { return }
    saveEdits(for: category)
  }

  private func endEditing() {
    editingCategoryID = nil
    draftName = ""
    draftDetails = ""
  }
}

// App entry point intentionally omitted; DayflowApp provides the main entry.

#Preview("Timeline Card Color Picker") {
  ColorOrganizerRoot()
    .environmentObject(CategoryStore())
    .frame(minWidth: 980, minHeight: 640)
}
