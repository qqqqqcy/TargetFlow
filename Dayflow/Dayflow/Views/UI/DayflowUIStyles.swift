//
//  DayflowUIStyles.swift
//  Dayflow
//
//  Reusable styling components for the new UI
//

import SwiftUI

extension View {
  /// A shared content surface for timeline panels, inspectors and settings.
  func dayflowPanel(cornerRadius: CGFloat = 12) -> some View {
    modifier(DayflowPanelStyle(cornerRadius: cornerRadius))
  }

  /// Applies a compact rounded control surface.
  func dayflowStyle(
    cornerRadius: CGFloat = 8,
    backgroundColor: Color = Color.dayflowAdaptive(
      light: .white, dark: NSColor(red: 27 / 255, green: 40 / 255, blue: 61 / 255, alpha: 1))
  ) -> some View {
    self
      .background(backgroundColor)
      .cornerRadius(cornerRadius)
  }

  /// Applies complete Dayflow style with circle shape
  func dayflowCircleStyle(
    backgroundColor: Color = Color.dayflowAdaptive(
      light: .white, dark: NSColor(red: 27 / 255, green: 40 / 255, blue: 61 / 255, alpha: 1))
  ) -> some View {
    self
      .background(backgroundColor)
      .clipShape(Circle())
  }
}

private struct DayflowPanelStyle: ViewModifier {
  @Environment(\.dayflowTheme) private var theme
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .background(theme.surfaceFill, in: shape)
      .overlay(shape.strokeBorder(theme.rightPanelBorder, lineWidth: 1).allowsHitTesting(false))
      .shadow(color: theme.rightPanelShadow, radius: 8, x: 0, y: 2)
  }
}

struct DayflowCircleButton<Content: View>: View {
  @Environment(\.dayflowTheme) private var theme
  let action: () -> Void
  let size: CGSize
  let pressedScale: CGFloat
  let pressAnimation: Animation
  @ViewBuilder let content: () -> Content

  init(
    width: CGFloat = 32,
    height: CGFloat = 32,
    pressedScale: CGFloat = 0.97,
    pressAnimation: Animation = .spring(response: 0.24, dampingFraction: 0.82),
    action: @escaping () -> Void,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.size = CGSize(width: width, height: height)
    self.pressedScale = pressedScale
    self.pressAnimation = pressAnimation
    self.action = action
    self.content = content
  }

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(theme.secondaryButtonFill)
          .overlay(Circle().strokeBorder(theme.secondaryButtonBorder, lineWidth: 1))

        content()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: size.width, height: size.height)
      .contentShape(Circle())
    }
    .buttonStyle(
      DayflowPressScaleButtonStyle(pressedScale: pressedScale, animation: pressAnimation)
    )
    .contentShape(Circle())
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }
}

struct DayflowPillButton: View {
  @Environment(\.dayflowTheme) private var theme
  let text: String
  let font: Font
  let foregroundColor: Color?
  let horizontalPadding: CGFloat
  let height: CGFloat
  let fixedWidth: CGFloat?

  init(
    text: String,
    font: Font = .system(size: 13, weight: .medium),
    foregroundColor: Color? = nil,
    horizontalPadding: CGFloat = 12,
    height: CGFloat = 32,
    fixedWidth: CGFloat? = nil
  ) {
    self.text = text
    self.font = font
    self.foregroundColor = foregroundColor
    self.horizontalPadding = horizontalPadding
    self.height = height
    self.fixedWidth = fixedWidth
  }

  var body: some View {
    Text(text)
      .font(font)
      .foregroundColor(foregroundColor ?? theme.textPrimary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .if(fixedWidth != nil) { view in
        view.frame(width: fixedWidth!, height: height)
      }
      .if(fixedWidth == nil) { view in
        view.padding(.horizontal, horizontalPadding)
          .frame(height: height)
      }
      .dayflowStyle(backgroundColor: theme.secondaryButtonFill)
  }
}

/// A brand-colored switch that stays legible when its window is inactive.
/// The accessibility representation retains the native toggle role and value.
struct DayflowToggleStyle: ToggleStyle {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 8) {
        configuration.label
        Capsule()
          .fill(configuration.isOn ? theme.primaryButtonFill : theme.targetsInactiveTrack)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(.white)
              .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
              .padding(2)
              .frame(width: 18, height: 18)
          }
          .frame(width: 30, height: 18)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: configuration.isOn)
      }
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .pointingHandCursor(enabled: isEnabled)
    .accessibilityRepresentation {
      Toggle(
        isOn: Binding(
          get: { configuration.isOn },
          set: { configuration.isOn = $0 }
        )
      ) {
        configuration.label
      }
      .toggleStyle(.switch)
      .disabled(!isEnabled)
    }
  }
}
