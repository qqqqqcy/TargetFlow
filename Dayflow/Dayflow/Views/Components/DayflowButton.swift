//
//  DayflowButton.swift
//  Dayflow
//
//  Custom button component with Dayflow branding
//

import AppKit
import SwiftUI

struct DayflowButton: View {
  let title: String
  let action: () -> Void
  var width: CGFloat? = nil
  var fontSize: CGFloat = 13
  var isSubtle: Bool = false

  @State private var isHovered = false
  @State private var showPulse = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  // Animation constants following Emil Kowalski principles
  private let hoverAnimation = Animation.spring(
    response: 0.22, dampingFraction: 0.8, blendDuration: 0)
  private let pressAnimation = Animation.spring(
    response: 0.3, dampingFraction: 0.65, blendDuration: 0)

  var body: some View {
    Button(action: {
      NSHapticFeedbackManager.defaultPerformer.perform(
        .levelChange,
        performanceTime: .default
      )

      if !reduceMotion {
        withAnimation(pressAnimation) { showPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          showPulse = false
        }
      }
      action()
    }) {
      Text(title)
        .font(.system(size: fontSize))
        .fontWeight(.semibold)
        .foregroundColor(isSubtle ? theme.secondaryButtonText : theme.primaryButtonText)
        .padding(.horizontal, DayflowLayout.buttonHorizontalInset)
        .frame(width: width, height: DayflowLayout.buttonHeight, alignment: .center)
        .background(
          ZStack {
            // Main background
            if isSubtle {
              theme.secondaryButtonFill
            } else {
              theme.primaryButtonFill
            }

            // Pulse effect
            if showPulse {
              Group {
                if isSubtle {
                  Color.gray.opacity(0.1)
                } else {
                  theme.primaryButtonFill
                    .opacity(0.3)
                }
              }
              .scaleEffect(1.2)
              .blur(radius: 10)
              .animation(.easeOut(duration: 0.3), value: showPulse)
            }
          }
        )
        .cornerRadius(DayflowLayout.buttonRadius)
        .shadow(
          color: theme.accent.opacity(isSubtle ? 0 : (isHovered ? 0.16 : 0.10)),
          radius: isHovered ? 8 : 5,
          x: 0,
          y: 3
        )
        .overlay(
          RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius)
            .strokeBorder(
              isSubtle ? theme.secondaryButtonBorder : theme.primaryButtonBorder,
              lineWidth: 1
            )
        )
        .opacity(isEnabled ? 1 : 0.5)
        .scaleEffect(reduceMotion ? 1.0 : (isHovered ? 1.02 : 1.0))
        .offset(y: reduceMotion ? 0 : (isHovered ? (isSubtle ? -1 : -2) : 0))
        .brightness(isHovered ? (isSubtle ? 0.05 : 0.08) : 0)
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97, animation: pressAnimation))
    .pointingHandCursor()
    .onHover { hovering in
      withAnimation(hoverAnimation) {
        isHovered = hovering
      }
    }
  }
}

struct DayflowButton_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 20) {
      DayflowButton(title: String(localized: "Start"), action: {})
      DayflowButton(title: String(localized: "Continue"), action: {}, width: 200)
      DayflowButton(title: String(localized: "Next"), action: {}, width: 120, fontSize: 14)
      DayflowButton(title: String(localized: "Subtle"), action: {}, isSubtle: true)
    }
    .padding(40)
    .background(Color.gray.opacity(0.1))
  }
}
