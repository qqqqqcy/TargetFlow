//
//  DayflowSurfaceButton.swift
//  Dayflow
//
//  Generic content button with unified Emil‑style hover/press interactions
//

import SwiftUI

struct DayflowSurfaceButton<Content: View>: View {
  let action: () -> Void
  @ViewBuilder let content: () -> Content

  var background: Color = Color.dayflowAdaptive(
    light: .white, dark: NSColor(red: 27 / 255, green: 40 / 255, blue: 61 / 255, alpha: 1))
  var foreground: Color = Color.dayflowAdaptive(
    light: NSColor(red: 32 / 255, green: 43 / 255, blue: 61 / 255, alpha: 1),
    dark: NSColor(red: 237 / 255, green: 243 / 255, blue: 252 / 255, alpha: 1))
  var borderColor: Color = Color.dayflowAdaptive(
    light: NSColor(red: 233 / 255, green: 237 / 255, blue: 243 / 255, alpha: 1),
    dark: NSColor(red: 49 / 255, green: 64 / 255, blue: 89 / 255, alpha: 1))
  var cornerRadius: CGFloat = 8
  var horizontalPadding: CGFloat = 18
  var verticalPadding: CGFloat = 12
  var minWidth: CGFloat? = nil
  var fixedHeight: CGFloat? = nil  // Fixed button height (vertical padding still applies to content)
  var showShadow: Bool = true
  var showOverlayStroke: Bool = false  // New parameter for white overlay stroke
  var isSecondaryStyle: Bool = false  // New parameter for white/secondary buttons
  var innerGlowColor: Color? = nil  // Soft inset glow (Figma "inset box-shadow")

  @State private var isHovered = false
  @State private var isPressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let hoverAnim = Animation.spring(response: 0.22, dampingFraction: 0.85)
  private let pressAnim = Animation.spring(response: 0.26, dampingFraction: 0.75)

  var body: some View {
    Button(action: {
      withAnimation(pressAnim) { isPressed = true }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        withAnimation(pressAnim) { isPressed = false }
        action()
      }
    }) {
      HStack(spacing: 10) {
        content()
          .foregroundColor(foreground)
      }
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .frame(minWidth: minWidth)
      .frame(height: fixedHeight)
      .background(background)
      .overlay(
        Group {
          if isSecondaryStyle {
            RoundedRectangle(cornerRadius: cornerRadius)
              .inset(by: 0.5)
              .stroke(borderColor, lineWidth: 1)
          } else if showOverlayStroke {
            RoundedRectangle(cornerRadius: cornerRadius)
              .inset(by: 0.75)
              .stroke(.white.opacity(0.17), lineWidth: 1.5)
          } else {
            RoundedRectangle(cornerRadius: cornerRadius)
              .inset(by: 0.5)
              .stroke(isHovered ? borderColor.opacity(1.0) : borderColor, lineWidth: 1)
          }
        }
      )
      .overlay(
        Group {
          if let innerGlowColor {
            InnerGlow(
              shape: RoundedRectangle(cornerRadius: cornerRadius),
              color: innerGlowColor,
              radius: 3
            )
          }
        }
      )
      .cornerRadius(cornerRadius)
      .if(isSecondaryStyle) { view in
        view
          .shadow(color: .black.opacity(showShadow ? 0.04 : 0), radius: 4, x: 0, y: 2)
      }
      .if(!isSecondaryStyle) { view in
        view
          .shadow(
            color: .black.opacity(showShadow ? (isHovered ? 0.10 : 0.06) : 0),
            radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2
          )
          .shadow(
            color: .black.opacity(showShadow ? (isHovered ? 0.06 : 0.04) : 0),
            radius: isHovered ? 2 : 1, x: 0, y: 1)
      }
      .brightness(isHovered ? 0.02 : 0)
      .dayflowPressScale(
        isPressed,
        enabled: !reduceMotion,
        pressedScale: 0.985,
        animation: pressAnim
      )
      .scaleEffect(reduceMotion ? 1.0 : (isHovered ? 1.02 : 1.0))
      .offset(y: reduceMotion ? 0 : (isHovered ? -1 : 0))
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(hoverAnim) { isHovered = hovering }
    }
    .pointingHandCursor()
  }
}
