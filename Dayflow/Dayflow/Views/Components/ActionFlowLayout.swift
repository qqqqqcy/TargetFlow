import SwiftUI

/// Wraps actions using their measured size rather than squeezing labels on small windows.
struct ActionFlowLayout: Layout {
  var spacing: CGFloat = DayflowLayout.actionSpacing

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let layout = arrange(subviews, width: proposal.width ?? .infinity)
    return layout.size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let layout = arrange(subviews, width: bounds.width)
    for (index, origin) in layout.origins.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: ProposedViewSize(layout.sizes[index])
      )
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat)
    -> (size: CGSize, origins: [CGPoint], sizes: [CGSize])
  {
    var origins: [CGPoint] = []
    var sizes: [CGSize] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    for view in subviews {
      let ideal = view.sizeThatFits(.unspecified)
      let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
      if x > 0 && x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      sizes.append(size)
      usedWidth = max(usedWidth, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: usedWidth, height: y + rowHeight), origins, sizes)
  }
}
