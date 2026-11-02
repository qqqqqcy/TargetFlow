import SwiftUI

enum TimelineScale {
  static let hourHeight: CGFloat = 168
}

/// Day-only density; the week timeline continues to use its own scale.
enum DayTimelineZoom {
  static let minimum = 25.0
  static let maximum = 800.0
  static let step = 25.0

  static func normalized(_ percent: Double) -> Double {
    guard percent.isFinite else { return 100 }
    return min(maximum, max(minimum, percent))
  }

  static func hourHeight(for percent: Double) -> CGFloat {
    TimelineScale.hourHeight * CGFloat(normalized(percent)) / 100
  }

  static func y(minutes: Double, hourHeight: CGFloat) -> CGFloat {
    CGFloat(minutes) * hourHeight / 60
  }

  static func cardHeight(minutes: Double, hourHeight: CGFloat) -> CGFloat {
    let raw = max(0, y(minutes: minutes, hourHeight: hourHeight))
    // Keep the existing 10pt minimum where it fits, but never extend a very
    // short card beyond its time interval into the next event when zoomed out.
    return min(raw, max(10, raw - 2))
  }

  static func anchoredOffset(_ offset: CGFloat, from oldHeight: CGFloat,
    to newHeight: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
    focusY: CGFloat = 0) -> CGFloat
  {
    let scaled = (max(0, offset) + focusY) / oldHeight * newHeight - focusY
    return min(max(0, contentHeight - viewportHeight), max(0, scaled))
  }
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
