import SwiftUI

enum TimelineScale {
  static let hourHeight: CGFloat = 168
}

enum TimelineCardLayout {
  static let iconLeadingInset: CGFloat = 16
  static let iconTextSpacing: CGFloat = 6
  static let faviconSize: CGFloat = 18
  static let faviconVerticalOffset: CGFloat = 0
  static let compactDurationThreshold: CGFloat = 13
  static let compactVerticalPadding: CGFloat = 0
  static let normalVerticalPadding: CGFloat = 6
  static let hoverScale: CGFloat = 1.005
  static let pressedScale: CGFloat = 0.992
}

enum TimelineTypography {
  static let cardTextFontSize: CGFloat = 13
  static let cardTextFontWeight: Font.Weight = .medium
  static let timeLabelFontSize: CGFloat = 10

  static func cardSecondaryTextFontSize(for cardTextFontSize: CGFloat) -> CGFloat {
    max(8, cardTextFontSize - 3)
  }
}
