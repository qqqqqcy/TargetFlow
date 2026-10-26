//
//  DayDistractionSummarySection.swift
//  Dayflow
//
//  Distraction section for the Day Summary right rail.
//

import SwiftUI

struct DayDistractionSummarySection: View {
  @Environment(\.dayflowTheme) private var theme

  let totalCapturedText: String
  let totalDistractedText: String
  let distractedRatio: Double
  let patternTitle: String
  let patternDescription: String
  let isSelectionEmpty: Bool
  let categories: [TimelineCategory]
  let selectedCategoryIDs: Set<UUID>
  let isEditingCategories: Bool
  var onEditCategories: () -> Void
  var onToggleCategory: (TimelineCategory) -> Void
  var onDoneEditing: () -> Void

  private enum Design {
    static let sectionSpacing: CGFloat = 16
    static let editButtonSize: CGFloat = 20
    static let editorOffsetY: CGFloat = 28
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.sectionSpacing) {
      header

      if isSelectionEmpty {
        Text("Edit categories to calculate distractions.")
          .font(.system(size: 11))
          .foregroundColor(theme.textSecondary)
      }

      DistractionSummaryCard(
        totalCaptured: totalCapturedText,
        totalDistracted: totalDistractedText,
        distractedRatio: distractedRatio,
        patternTitle: patternTitle,
        patternDescription: patternDescription
      )
      .frame(maxWidth: .infinity)
      .opacity(isSelectionEmpty ? 0.45 : 1)
    }
    .overlay(alignment: .topLeading) {
      if isEditingCategories {
        DayCategorySelectionEditor(
          categories: categories,
          selectedCategoryIDs: selectedCategoryIDs,
          helperText: String(localized: "Pick the categories that count towards Distractions"),
          onToggle: onToggleCategory,
          onDone: onDoneEditing
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: Design.editorOffsetY)
        .onTapGesture {}
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 6) {
      Text("Distractions so far")
        .font(.system(size: 22, weight: .semibold))
        .foregroundColor(theme.textPrimary)

      Spacer()

      CategoryEditCircleButton(
        action: onEditCategories,
        diameter: Design.editButtonSize,
        accessibilityLabel: "设置分心统计事件"
      )
    }
  }
}
