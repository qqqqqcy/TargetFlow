import SwiftUI

enum SidebarIcon: String, CaseIterable {
  case timeline
  case settings

  var assetName: String? {
    self == .timeline ? "TimelineIcon" : nil
  }

  var systemNameFallback: String? {
    switch self {
    case .timeline: return nil
    case .settings: return "gearshape.fill"
    }
  }

  var displayName: String {
    switch self {
    case .timeline: return String(localized: "Timeline")
    case .settings: return String(localized: "Settings")
    }
  }

  var analyticsTabName: String { rawValue }
}

struct SidebarView: View {
  @Binding var selectedIcon: SidebarIcon
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selectionNamespace

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(SidebarIcon.allCases, id: \.self) { icon in
        SidebarIconButton(
          icon: icon, isSelected: selectedIcon == icon, selectionNamespace: selectionNamespace
        ) {
          selectedIcon = icon
        }
      }
    }
    .padding(.leading, 14)
    .animation(reduceMotion ? nil : DayflowMotion.selection, value: selectedIcon)
  }
}

struct SidebarIconButton: View {
  @Environment(\.dayflowTheme) private var theme
  let icon: SidebarIcon
  let isSelected: Bool
  var showBadge = false
  var selectionNamespace: Namespace.ID? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon == .timeline ? "rectangle.stack" : "gearshape")
          .font(.system(size: 15, weight: .medium))
          .frame(width: 18)
        Text(icon.displayName)
          .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
        Spacer(minLength: 0)
        if showBadge { Circle().frame(width: 5, height: 5) }
      }
      .foregroundStyle(isSelected ? theme.sidebarLabelActive : theme.sidebarLabel)
      .padding(.leading, 18)
      .padding(.trailing, 12)
      .frame(height: 46)
      .background {
        if isSelected {
          if let selectionNamespace {
            SidebarSelectionShape()
              .fill(theme.panelSolid)
              .matchedGeometryEffect(id: "sidebarSelection", in: selectionNamespace)
              .allowsHitTesting(false)
          } else {
            SidebarSelectionShape()
              .fill(theme.panelSolid)
              .allowsHitTesting(false)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .pointingHandCursor()
  }
}

private struct SidebarSelectionShape: Shape {
  func path(in rect: CGRect) -> Path {
    let radius: CGFloat = min(12, min(rect.width, rect.height) / 2)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    // Extend into the sidebar above and below the row to meet the content panel smoothly.
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
      tangent2End: CGPoint(x: rect.maxX, y: rect.minY - radius), radius: radius)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + radius))
    path.addArc(
      tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY), radius: radius)
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
      tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addArc(
      tangent1End: CGPoint(x: rect.minX, y: rect.minY),
      tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
    path.closeSubpath()
    return path
  }
}
