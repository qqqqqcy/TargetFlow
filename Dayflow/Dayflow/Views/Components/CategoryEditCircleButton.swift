import SwiftUI

// Compact action used next to event categories.
struct CategoryEditCircleButton: View {
  @Environment(\.dayflowTheme) private var theme

  let action: () -> Void
  var diameter: CGFloat = DayflowLayout.buttonHeight
  var iconSize: CGFloat? = nil
  var accessibilityLabel: String = String(localized: "事件与目标")

  var body: some View {
    let resolvedIconSize = iconSize ?? diameter * 0.6
    let shape = RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius)

    Button(action: action) {
      Image("CategoryEditButton")
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .foregroundColor(theme.primaryButtonText)
        .frame(width: resolvedIconSize, height: resolvedIconSize)
        .frame(width: diameter, height: diameter)
        .background(shape.fill(theme.editButtonFill))
        .overlay(InnerGlow(shape: shape, color: theme.editButtonInnerGlow, radius: 3))
        .overlay(shape.strokeBorder(theme.editButtonBorder, lineWidth: 0.75))
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel(accessibilityLabel)
  }
}
