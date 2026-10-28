import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ColorOrganizerRoot: View {
  enum PresentationStyle {
    case embedded
    case sheet
  }

  var presentationStyle: PresentationStyle = .embedded
  var onDismiss: (() -> Void)?
  var completionButtonTitle: String?
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
  @State private var showFirstTimeHints: Bool = !AppStoragePaths.defaults.bool(
    forKey: CategoryStore.StoreKeys.hasUsedApp)
  @State private var pendingScrollTarget: UUID? = nil
  @State private var isAddButtonHovered: Bool = false

  init(
    presentationStyle: PresentationStyle = .embedded,
    onDismiss: (() -> Void)? = nil,
    completionButtonTitle: String? = nil
  ) {
    self.presentationStyle = presentationStyle
    self.onDismiss = onDismiss
    self.completionButtonTitle = completionButtonTitle
    _stage = State(initialValue: .details)
  }

  private var categories: [TimelineCategory] {
    categoryStore.editableCategories
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
    .onDisappear {
      commitPendingEditsIfNeeded()
    }
  }

  private var contentCard: some View {
    GeometryReader { proxy in
      let isCompact = proxy.size.width < 960
      let sideBySide = proxy.size.width >= 720

      VStack(spacing: 0) {
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

        ScrollView {
          ZStack(alignment: .topLeading) {
            Group {
              if stage == .details {
                if sideBySide {
                  HStack(alignment: .top, spacing: 28) {
                    instructionsPanel(isCompact: isCompact)
                      .frame(width: isCompact ? 210 : 240, alignment: .leading)
                    categoryEditorPanel(isCompact: isCompact)
                  }
                } else {
                  VStack(alignment: .leading, spacing: 20) {
                    instructionsPanel(isCompact: true)
                    categoryEditorPanel(isCompact: true)
                  }
                }
              } else {
                if sideBySide {
                  HStack(alignment: .top, spacing: 28) {
                    colorPickerPanel
                      .frame(width: 240, alignment: .leading)
                    colorAssignmentPanel(isCompact: isCompact)
                  }
                } else {
                  VStack(alignment: .leading, spacing: 20) {
                    colorPickerPanel
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

  private func instructionsPanel(isCompact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 20) {
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

      VStack(alignment: .leading, spacing: 16) {
        instructionRow(
          icon: "text.alignleft",
          text:
            String(
              localized:
                "Write down what you want to do and add details, such as fixing a login issue or preparing for an interview."
            )
        )
        .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)

        instructionRow(
          icon: "checkmark.circle",
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
      Image(systemName: icon)
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

  private var colorPickerPanel: some View {
    VStack(alignment: .leading, spacing: 24) {
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
            maxLight: 90,
            numPoints: numPoints,
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
            categoryStore.persist()
            withAnimation(.easeInOut(duration: 0.25)) {
              stage = .colors
            }
          }
        }
      } else {
        SettingsSecondaryButton(title: String(localized: "Back")) {
          withAnimation(.easeInOut(duration: 0.25)) {
            isDraggingColor = false
            stage = .details
          }
        }

        SettingsPrimaryButton(
          title: completionButtonTitle ?? String(localized: "Next"), systemImage: "chevron.right",
          isDisabled: categories.isEmpty
        ) {
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

      categoryStore.addCategory(name: candidate)

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
    if didRename {
      categoryStore.renameCategory(id: category.id, to: trimmedName)

    }
    categoryStore.updateDetails(draftDetails, for: category.id)
    endEditing()
  }

  private func deleteCategory(_ category: TimelineCategory) {
    withAnimation(.easeInOut(duration: 0.2)) {
      if editingCategoryID == category.id {
        endEditing()
      }

      categoryStore.removeCategory(id: category.id)

    }
  }

  private func assignColor(_ hex: String, to category: TimelineCategory) {
    let previousHex = category.colorHex

    categoryStore.assignColor(hex, to: category.id)

    guard hex != previousHex else { return }

  }

  private func updatePaletteRadius(_ newRadius: Double) {
    normalizedRadius = newRadius
  }

  private func updatePaletteAngle(_ newAngle: Double) {
    currentAngle = newAngle
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
