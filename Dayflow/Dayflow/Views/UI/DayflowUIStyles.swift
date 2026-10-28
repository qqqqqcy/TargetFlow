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
