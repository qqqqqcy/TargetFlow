//
//  CategoryPickerView.swift
//  Dayflow
//

import SwiftUI

struct CategoryPill: View {
  @Environment(\.dayflowTheme) private var theme

  let category: TimelineCategory
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 4) {
        // Colored dot
        Circle()
          .fill(categoryColor)
          .frame(width: 8, height: 8)

        // Category name - no line limit, text can wrap if needed
        Text(category.name)
          .font(Font.custom("Figtree", size: 10).weight(.medium))
          .foregroundColor(isSelected ? theme.controlText : theme.chipText)
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(nil)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(pillBackground)
      .cornerRadius(6)
      .overlay(
        Group {
          if category.isIdle && !isSelected {
            // Dotted border for Idle category
            RoundedRectangle(cornerRadius: 6)
              .inset(by: 0.375)
              .stroke(style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
              .foregroundColor(pillBorder)
          } else {
            RoundedRectangle(cornerRadius: 6)
              .inset(by: 0.375)
              .stroke(pillBorder, lineWidth: 0.75)
          }
        }
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  private var categoryColor: Color {
    if let nsColor = NSColor(hex: category.colorHex) {
      return Color(nsColor: nsColor)
    }
    return Color.gray
  }

  private var pillBackground: Color {
    isSelected ? theme.controlFill : theme.chipFill
  }

  private var pillBorder: Color {
    isSelected ? theme.controlBorder : theme.chipBorder
  }
}
