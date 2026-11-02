import SwiftUI

/// Places zoom beside navigation at normal widths and below it in narrow panels.
/// A Layout keeps one stable navigation subtree (including its matched segment).
struct DayTimelineHeaderLayout: Layout {
  private let inlineMinimumWidth: CGFloat = 360

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? inlineMinimumWidth
    return CGSize(width: width, height: width >= inlineMinimumWidth ? 36 : 68)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let zoomSize = subviews[1].sizeThatFits(.unspecified)
    let inline = bounds.width >= inlineMinimumWidth
    let navigationWidth = inline ? max(0, bounds.width - zoomSize.width - 8) : bounds.width
    subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: navigationWidth, height: 36))
    subviews[1].place(
      at: CGPoint(x: max(bounds.minX, bounds.maxX - zoomSize.width),
        y: bounds.minY + (inline ? 4 : 40)),
      proposal: ProposedViewSize(zoomSize))
  }
}

/// Kept separate from navigation so all three controls fit even in a narrow day panel.
struct DayTimelineZoomControls: View {
  @ObservedObject var zoom: DayTimelineZoomState
  @Environment(\.dayflowTheme) private var theme

  private var value: Double { zoom.percent }
  private var label: String { String(format: "%.0f%%", value) }

  var body: some View {
    HStack(spacing: 0) {
      Button { zoom.set(value - DayTimelineZoom.step) } label: {
        Image(systemName: "minus").frame(width: 30, height: 28)
      }
      .disabled(value == DayTimelineZoom.minimum)
      .opacity(value == DayTimelineZoom.minimum ? 0.35 : 1)
      .accessibilityLabel(Text("Zoom out day timeline"))
      .help("Zoom out day timeline")
      .accessibilityIdentifier("dayTimelineZoomOut")

      Button { zoom.set(100) } label: {
        Text(verbatim: label)
          .monospacedDigit()
          .frame(width: 48, height: 28)
      }
      .accessibilityLabel(Text("Day timeline zoom"))
      .accessibilityValue(Text(verbatim: label))
      .accessibilityHint(Text("Reset day timeline zoom to 100%"))
      .help("Reset day timeline zoom to 100%")
      .accessibilityIdentifier("dayTimelineZoomReset")

      Button { zoom.set(value + DayTimelineZoom.step) } label: {
        Image(systemName: "plus").frame(width: 30, height: 28)
      }
      .disabled(value == DayTimelineZoom.maximum)
      .opacity(value == DayTimelineZoom.maximum ? 0.35 : 1)
      .accessibilityLabel(Text("Zoom in day timeline"))
      .help("Zoom in day timeline")
      .accessibilityIdentifier("dayTimelineZoomIn")
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(theme.controlText)
    .buttonStyle(.plain)
    .background(theme.controlFill, in: RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DayflowLayout.buttonRadius)
        .strokeBorder(theme.controlBorder, lineWidth: 0.75)
    }
    .fixedSize()
    .help("Pinch to zoom the day timeline. Scroll with two fingers to move through time.")
  }
}
