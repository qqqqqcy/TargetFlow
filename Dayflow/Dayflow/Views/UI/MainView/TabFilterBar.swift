import SwiftUI

/// Normalizes a category name so chips and timeline cards match regardless of
/// case or stray whitespace.
func categoryFilterKey(_ name: String) -> String {
  name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

struct TabFilterBar: View {
  let categories: [TimelineCategory]
  let idleCategory: TimelineCategory?
  @Binding var mutedCategoryKeys: Set<String>
  let onMoveCategory: (_ id: UUID, _ targetID: UUID) -> Void

  var isVertical = false

  @Environment(\.dayflowTheme) private var theme
  @State private var chipRowWidth: CGFloat = 0
  @State private var draggedCategoryID: UUID?

  private let chipRowHeight: CGFloat = 26

  var body: some View {
    if isVertical {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(categories) { category in
          reorderableChip(for: category)
        }
        if let idleCategory { chip(for: idleCategory, isIdle: true) }
      }
    } else {
      horizontalFilters
    }
  }

  private var horizontalFilters: some View {
    GeometryReader { geometry in
      let availableWidth = max(0, geometry.size.width)
      let maxChipRowWidth = availableWidth
      let hasMeasuredChipRow = chipRowWidth > 0
      let isOverflowing = hasMeasuredChipRow && chipRowWidth > maxChipRowWidth
      let chipRowFrameWidth =
        hasMeasuredChipRow
        ? min(chipRowWidth, maxChipRowWidth)
        : maxChipRowWidth

      ZStack(alignment: .topLeading) {
        visibleChipRow(width: chipRowFrameWidth)
          .frame(width: availableWidth, height: chipRowHeight, alignment: .leading)
          .overlay(alignment: .trailing) {
            if isOverflowing {
              overflowGradient
            }
          }

        measuredChipRow
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .frame(width: availableWidth, height: chipRowHeight, alignment: .leading)
    }
    .frame(height: chipRowHeight)
    .onPreferenceChange(ChipRowWidthPreferenceKey.self) { chipRowWidth = $0 }
  }

  struct CategoryChip: View {
    @Environment(\.dayflowTheme) private var theme

    let category: TimelineCategory
    let isIdle: Bool
    let isMuted: Bool
    let onTap: () -> Void

    var body: some View {
      Button(action: onTap) {
        chipLabel
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .opacity(isMuted ? 0.55 : 1)
      .help(
        isMuted
          ? "已弱化此事件的时间线卡片，再次点击恢复"
          : "点击弱化此事件的时间线卡片"
      )
      .animation(.easeOut(duration: 0.15), value: isMuted)
    }

    private var chipLabel: some View {
      HStack(spacing: 10) {
        Image(systemName: isMuted ? "square" : "checkmark.square.fill")
          .font(.system(size: 12))
          .foregroundStyle(isMuted ? theme.textMuted : theme.accent)
        Circle()
          .fill(Color(hex: category.colorHex).opacity(0.75))
          .frame(width: 5, height: 5)

        if isMuted {
          Image(systemName: "eye.slash.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(theme.chipText.opacity(0.7))
        }

        Text(category.name)
          .font(Font.system(size: 11).weight(.regular))
          .foregroundColor(theme.chipText)
          .lineLimit(1)
          .fixedSize()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(height: 26)
      .background(theme.chipFill)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(theme.chipBorder, lineWidth: 0.5)
      )
    }
  }

  private func visibleChipRow(width: CGFloat) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      chipRowContent(isReorderable: true)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: chipRowHeight)
    }
    .frame(width: max(0, width), height: chipRowHeight, alignment: .leading)
    .clipped()
  }

  private var measuredChipRow: some View {
    chipRowContent(isReorderable: false)
      .fixedSize(horizontal: true, vertical: false)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: ChipRowWidthPreferenceKey.self, value: proxy.size.width)
        }
      )
  }

  /// The hidden measuring copy passes `isReorderable: false` so only the
  /// visible row registers drag sources and drop targets.
  private func chipRowContent(isReorderable: Bool) -> some View {
    HStack(spacing: 5) {
      ForEach(categories) { category in
        if isReorderable {
          reorderableChip(for: category)
        } else {
          chip(for: category, isIdle: false)
        }
      }

      if let idleCategory {
        chip(for: idleCategory, isIdle: true)
      }
    }
    .padding(.leading, 2)
  }

  private func chip(for category: TimelineCategory, isIdle: Bool) -> some View {
    let key = categoryFilterKey(category.name)
    return CategoryChip(
      category: category,
      isIdle: isIdle,
      isMuted: mutedCategoryKeys.contains(key),
      onTap: { toggleMuted(key) }
    )
  }

  private func reorderableChip(for category: TimelineCategory) -> some View {
    let categoryID = category.id
    return chip(for: category, isIdle: false)
      .onDrag {
        draggedCategoryID = categoryID
        return NSItemProvider(object: categoryID.uuidString as NSString)
      }
      .onDrop(
        of: ["public.text"],
        delegate: CategoryChipDropDelegate(
          targetCategoryID: categoryID,
          draggedCategoryID: $draggedCategoryID,
          onMoveCategory: onMoveCategory
        )
      )
  }

  private func toggleMuted(_ key: String) {
    if mutedCategoryKeys.contains(key) {
      mutedCategoryKeys.remove(key)
    } else {
      mutedCategoryKeys.insert(key)
    }
  }

  private var overflowGradient: some View {
    LinearGradient(
      gradient: Gradient(colors: [Color.clear, theme.panelSolid]),
      startPoint: .leading,
      endPoint: .trailing
    )
    .frame(width: 40)
    .allowsHitTesting(false)
  }

  private struct CategoryChipDropDelegate: DropDelegate {
    let targetCategoryID: UUID
    @Binding var draggedCategoryID: UUID?
    let onMoveCategory: (_ id: UUID, _ targetID: UUID) -> Void

    func dropEntered(info: DropInfo) {
      guard let draggedID = draggedCategoryID, draggedID != targetCategoryID else { return }
      withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
        onMoveCategory(draggedID, targetCategoryID)
      }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
      DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
      draggedCategoryID = nil
      return true
    }
  }

  private struct ChipRowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = nextValue()
    }
  }
}
