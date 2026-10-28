import SwiftUI

#if os(macOS)

  struct DayflowPressScaleButtonStyle: ButtonStyle {
    let enabled: Bool
    let pressedScale: CGFloat
    let animation: Animation

    init(
      enabled: Bool = true,
      pressedScale: CGFloat = 0.97,
      animation: Animation = .spring(response: 0.24, dampingFraction: 0.82)
    ) {
      self.enabled = enabled
      self.pressedScale = pressedScale
      self.animation = animation
    }

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .dayflowPressScale(
          configuration.isPressed,
          enabled: enabled,
          pressedScale: pressedScale,
          animation: animation
        )
    }
  }

  private struct HoverScaleModifier: ViewModifier {
    let enabled: Bool
    let scale: CGFloat
    let animation: Animation
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
      content
        .scaleEffect(isHovering && !reduceMotion ? scale : 1)
        .animation(reduceMotion ? nil : animation, value: isHovering)
        .onHover { hovering in
          isHovering = enabled ? hovering : false
        }
        .onChange(of: enabled) { _, isEnabled in
          if !isEnabled {
            isHovering = false
          }
        }
    }
  }

  private struct PressScaleModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPressed: Bool
    let enabled: Bool
    let scale: CGFloat
    let animation: Animation

    func body(content: Content) -> some View {
      content
        .scaleEffect(enabled && isPressed && !reduceMotion ? scale : 1)
        .animation(reduceMotion ? nil : animation, value: isPressed)
    }
  }

  extension View {
    // Uses native SwiftUI pointer style on macOS 15+.
    // For macOS 14, this is intentionally a no-op.
    //
    // `enabled` must not pick between `if`/`else` branches: that makes the
    // wrapped view's identity depend on it, so every toggle tears down and
    // rebuilds the whole subtree. When that happens while the pointer is
    // moving (e.g. the timeline's hour column toggling on card selection),
    // AppKit's mouseMoved hit-test walks into the half-deleted subtree and
    // AttributeGraph aborts ("deleting updating attribute"). Passing a nil
    // style keeps a single stable view.
    @ViewBuilder
    func pointingHandCursor(enabled: Bool = true) -> some View {
      if #available(macOS 15.0, *) {
        self.pointerStyle(enabled ? .link : nil)
      } else {
        self
      }
    }

    func hoverScaleEffect(
      enabled: Bool = true,
      scale: CGFloat = 1.02,
      animation: Animation = .spring(response: 0.24, dampingFraction: 0.82)
    ) -> some View {
      modifier(HoverScaleModifier(enabled: enabled, scale: scale, animation: animation))
    }

    func dayflowPressScale(
      _ isPressed: Bool,
      enabled: Bool = true,
      pressedScale: CGFloat = 0.97,
      animation: Animation = .spring(response: 0.24, dampingFraction: 0.82)
    ) -> some View {
      modifier(
        PressScaleModifier(
          isPressed: isPressed, enabled: enabled, scale: pressedScale, animation: animation)
      )
    }
  }
#endif
