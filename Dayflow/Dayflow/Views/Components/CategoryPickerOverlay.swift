import AppKit
import SwiftUI

struct CategoryPickerOverlay: View {
  @Environment(\.dayflowTheme) private var theme

  let categories: [TimelineCategory]
  let currentCategoryName: String
  var onSelect: (TimelineCategory) -> Void
  var onNavigateToEditor: () -> Void
  var onDismiss: () -> Void

  private var orderedCategories: [TimelineCategory] {
    let trimmedCurrent = currentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let sorted = categories.sorted { lhs, rhs in
      lhs.order < rhs.order
    }

    guard
      let index = sorted.firstIndex(where: {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmedCurrent
      })
    else {
      return sorted
    }

    var reordered = sorted
    let selected = reordered.remove(at: index)
    reordered.insert(selected, at: 0)
    return reordered
  }

  var body: some View {
    VStack(spacing: 12) {
      FlowLayout(spacing: 6, rowSpacing: 8) {
        ForEach(orderedCategories) { category in
          Button {
            onSelect(category)
          } label: {
            CategoryPickerPill(
              category: category,
              isSelected: isSelected(category),
              isDark: theme.isDark
            )
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }
      }
      .padding(.trailing, 32)
      .frame(maxWidth: .infinity, alignment: .leading)

      Rectangle()
        .fill(theme.rightPanelDivider)
        .frame(height: 1)

      helperContent
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundView)
    .clipShape(
      RoundedRectangle(cornerRadius: 9)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          theme.popoverBorder,
          lineWidth: 1
        )
    )
    .overlay(alignment: .topTrailing) {
      dismissButton
    }
  }

  private var dismissButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundColor(theme.accent)
        .frame(width: DayflowLayout.buttonHeight, height: DayflowLayout.buttonHeight)
        .background(
          theme.accent.opacity(0.08),
          in: RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius)
        )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .accessibilityLabel("Done")
  }

  private var backgroundView: some View {
    theme.popoverFill
  }

  private var helperContent: some View {
    let baseFont = Font.system(size: 12)
    let baseColor = theme.textSecondary
    let linkColor = theme.accent
    let linkURL = URL(string: "dayflow://category-editor")!

    var intro = AttributedString(
      String(
        localized:
          "补充事件的具体内容和范围，帮助识别实际发生的事情。 "
      )
    )
    intro.font = baseFont
    intro.foregroundColor = baseColor

    var link = AttributedString("管理事件")
    link.font = baseFont
    link.foregroundColor = linkColor
    link.underlineStyle = .single
    link.link = linkURL

    var period = AttributedString("。")
    period.font = baseFont
    period.foregroundColor = baseColor

    let attributed = intro + link + period

    return Text(attributed)
      .fixedSize(horizontal: false, vertical: true)
      .environment(
        \.openURL,
        OpenURLAction { url in
          guard url == linkURL else { return .systemAction }
          onNavigateToEditor()
          return .handled
        })
  }

  private func isSelected(_ category: TimelineCategory) -> Bool {
    let trimmedCurrent = currentCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == trimmedCurrent
  }
}

private struct CategoryPickerPill: View {
  @Environment(\.dayflowTheme) private var theme
  let category: TimelineCategory
  let isSelected: Bool
  var isDark: Bool = false

  private var categoryColor: Color {
    if let nsColor = NSColor(hex: category.colorHex) {
      return Color(nsColor: nsColor)
    }
    return Color.gray
  }

  private var background: Color {
    isSelected ? theme.accent.opacity(0.1) : theme.cardFill
  }

  private var borderColor: Color {
    isSelected ? theme.accent.opacity(0.4) : theme.cardBorder
  }

  private var textColor: Color {
    isSelected ? theme.accent : theme.textPrimary
  }

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(categoryColor)
        .frame(width: 10, height: 10)

      Text(category.name)
        .font(
          Font.system(size: 13)
            .weight(.medium)
        )
        .foregroundColor(textColor)
        .lineLimit(1)
    }
    .padding(.horizontal, DayflowLayout.buttonHorizontalInset)
    .frame(height: DayflowLayout.buttonHeight)
    .background(background)
    .overlay(
      RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius)
        .inset(by: 0.25)
        .stroke(style: strokeStyle)
        .foregroundColor(borderColor)
    )
    .cornerRadius(DayflowLayout.buttonRadius)
  }

  private var strokeStyle: StrokeStyle {
    if category.isIdle && !isSelected {
      return StrokeStyle(lineWidth: 0.75, dash: [2, 2])
    }
    return StrokeStyle(lineWidth: 0.5)
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  var rowSpacing: CGFloat = 6

  func makeCache(subviews: Subviews) {
    ()
  }

  func updateCache(_ cache: inout (), subviews: Subviews) {}

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowWidth: CGFloat = 0

    for subview in subviews {
      let idealSize = subview.sizeThatFits(.unspecified)
      let size = subview.sizeThatFits(
        ProposedViewSize(width: min(idealSize.width, maxWidth), height: nil))
      let proposedWidth = size.width

      if rowWidth > 0 && rowWidth + spacing + proposedWidth > maxWidth {
        totalHeight += rowHeight + rowSpacing
        maxRowWidth = max(maxRowWidth, rowWidth)
        rowWidth = proposedWidth
        rowHeight = size.height
      } else {
        rowWidth = rowWidth == 0 ? proposedWidth : rowWidth + spacing + proposedWidth
        rowHeight = max(rowHeight, size.height)
      }
    }

    maxRowWidth = max(maxRowWidth, rowWidth)
    totalHeight += rowHeight

    return CGSize(width: maxRowWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var origin = CGPoint(x: bounds.minX, y: bounds.minY)
    var currentRowHeight: CGFloat = 0

    for subview in subviews {
      let idealSize = subview.sizeThatFits(.unspecified)
      let size = subview.sizeThatFits(
        ProposedViewSize(width: min(idealSize.width, bounds.width), height: nil))
      if origin.x > bounds.minX && origin.x + size.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += currentRowHeight + rowSpacing
        currentRowHeight = 0
      }

      subview.place(
        at: CGPoint(x: origin.x, y: origin.y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )

      origin.x += size.width + spacing
      currentRowHeight = max(currentRowHeight, size.height)
    }
  }
}
