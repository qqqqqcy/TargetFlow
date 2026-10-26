import SwiftUI

/// Shared timing for navigation, overlays and small control feedback.
enum DayflowMotion {
  static let selection = Animation.spring(response: 0.28, dampingFraction: 0.9)
  static let content = Animation.easeInOut(duration: 0.20)
  static let presentation = Animation.spring(response: 0.32, dampingFraction: 0.92)

  static func transition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion
      ? .opacity
      : .opacity.combined(with: .offset(y: 6))
  }
}
