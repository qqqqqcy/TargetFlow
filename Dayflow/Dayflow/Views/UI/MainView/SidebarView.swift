import SwiftUI

private enum SidebarMetrics {
  static let itemSpacing: CGFloat = 5.25
  static let scale: CGFloat = 1.1
  static let itemSize: CGFloat = 56 * scale
  static let selectedBackgroundSize: CGFloat = 30 * scale
  static let selectedBackgroundRadius: CGFloat = 10
  static let iconSize: CGFloat = 16 * scale
  static let fallbackSymbolSize: CGFloat = 15 * scale
  static let badgeSize: CGFloat = 8 * scale
  static let badgeOffsetX: CGFloat = 10 * scale
  static let badgeOffsetY: CGFloat = -10 * scale
  static let iconContainerSize: CGFloat = 34 * scale
  static let iconLabelSpacing: CGFloat = 3
  static let labelFontSize: CGFloat = 11 * scale
}

enum SidebarIcon: String, CaseIterable {
  case timeline
  case target
  case settings

  var assetName: String? {
    self == .timeline ? "TimelineIcon" : nil
  }

  var systemNameFallback: String? {
    switch self {
    case .timeline: return nil
    case .target: return "target"
    case .settings: return "gearshape.fill"
    }
  }

  var displayName: String {
    switch self {
    case .timeline: return String(localized: "Timeline")
    case .target: return "Target"
    case .settings: return String(localized: "Settings")
    }
  }

  var analyticsTabName: String { rawValue }
}

struct SidebarView: View {
  @Binding var selectedIcon: SidebarIcon

  var body: some View {
    VStack(alignment: .center, spacing: SidebarMetrics.itemSpacing) {
      ForEach(SidebarIcon.allCases, id: \.self) { icon in
        SidebarIconButton(
          icon: icon,
          isSelected: selectedIcon == icon,
          action: { selectedIcon = icon }
        )
        .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      }
    }
  }

}

struct SidebarIconButton: View {
  @Environment(\.dayflowTheme) private var theme

  let icon: SidebarIcon
  let isSelected: Bool
  var showBadge: Bool = false
  let action: () -> Void

  private var iconColor: Color {
    isSelected ? theme.sidebarIconActive : theme.sidebarIcon
  }

  private var labelColor: Color {
    isSelected ? theme.sidebarLabelActive : theme.sidebarLabel
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: SidebarMetrics.iconLabelSpacing) {
        iconBox

        Text(icon.displayName)
          .font(.custom("Figtree", size: SidebarMetrics.labelFontSize))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundColor(labelColor)
      }
      .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(DayflowPressScaleButtonStyle())
    .contentShape(Rectangle())
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursor()
  }

  private var iconBox: some View {
    let shape = RoundedRectangle(
      cornerRadius: SidebarMetrics.selectedBackgroundRadius, style: .continuous)

    return ZStack {
      if isSelected {
        shape
          .fill(theme.sidebarSelectedFill)
          .overlay(InnerGlow(shape: shape, color: theme.sidebarSelectedInnerGlow, radius: 3))
          .overlay(shape.strokeBorder(theme.sidebarSelectedBorder, lineWidth: 0.58))
          .shadow(color: theme.sidebarSelectedShadow, radius: 2, x: 0, y: 1)
          .frame(
            width: SidebarMetrics.selectedBackgroundSize,
            height: SidebarMetrics.selectedBackgroundSize
          )
      }

      iconImage
        .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)

      if showBadge {
        Circle()
          .fill(theme.accent)
          .frame(width: SidebarMetrics.badgeSize, height: SidebarMetrics.badgeSize)
          .offset(x: SidebarMetrics.badgeOffsetX, y: SidebarMetrics.badgeOffsetY)
      }
    }
    .frame(width: SidebarMetrics.iconContainerSize, height: SidebarMetrics.iconContainerSize)
  }

  @ViewBuilder
  private var iconImage: some View {
    if let asset = icon.assetName {
      Image(asset)
        .resizable()
        .interpolation(.high)
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundColor(iconColor)
    } else if let sys = icon.systemNameFallback {
      Image(systemName: sys)
        .font(.system(size: SidebarMetrics.fallbackSymbolSize))
        .foregroundColor(iconColor)
    }
  }
}
