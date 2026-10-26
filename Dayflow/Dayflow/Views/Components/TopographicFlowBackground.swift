import SwiftUI

/// Native interpretation of React Drops' Topographic Flow visual concept.
/// https://reactdrops.dev/components/background/topographic-flow
/// Drawn independently in SwiftUI; no React runtime or third-party source is embedded.
struct TopographicFlowBackground: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var isVisible = false
  @State private var elapsed: TimeInterval = 0
  @State private var resumedAt: Date?

  private var isAnimating: Bool {
    isVisible && scenePhase == .active && !reduceMotion
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isAnimating)) { timeline in
      let time = reduceMotion ? 0 : elapsed + (resumedAt.map {
        timeline.date.timeIntervalSince($0)
      } ?? 0)

      Canvas { context, size in
        for level in 0..<22 {
          let path = contour(level: level, size: size, time: time)
          let isMajor = level.isMultiple(of: 4)
          context.stroke(
            path,
            with: .color(.white.opacity(isMajor ? 0.20 : 0.10)),
            lineWidth: isMajor ? 0.9 : 0.6
          )
        }
      }
    }
    .mask {
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .white.opacity(0.35), location: 0.25),
          .init(color: .white, location: 0.48),
          .init(color: .white, location: 0.78),
          .init(color: .clear, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .opacity(theme.isDark ? 0.85 : 1)
    .clipped()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .onChange(of: isAnimating) { _, animating in
      if animating {
        resumedAt = .now
      } else if let start = resumedAt {
        elapsed += Date.now.timeIntervalSince(start)
        resumedAt = nil
      }
    }
  }

  private func contour(level: Int, size: CGSize, time: TimeInterval) -> Path {
    let phase = time * 0.12
    let elevation = Double(level)
    let radius = 24 + elevation * 13
    let center = CGPoint(
      x: size.width * (0.85 + 0.08 * sin(phase * 0.7)),
      y: size.height * (0.57 + 0.025 * cos(phase * 0.6))
    )
    var path = Path()

    for step in 0..<144 {
      let angle = Double(step) / 144 * .pi * 2
      let distortion =
        1 + 0.14 * sin(angle * 3 + phase + elevation * 0.09)
        + 0.075 * cos(angle * 5 - phase * 0.8 + elevation * 0.05)
      let distance = radius * distortion
      let point = CGPoint(
        x: center.x + cos(angle) * distance,
        y: center.y + sin(angle) * distance * 1.45
      )
      if step == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    path.closeSubpath()
    return path
  }
}

#Preview("Topographic Flow · Light") {
  TopographicFlowBackground()
    .frame(width: 166, height: 760)
    .background(DayflowTheme.light.sidebarBackground)
    .dayflowTheme(.light)
}

#Preview("Topographic Flow · Dark") {
  TopographicFlowBackground()
    .frame(width: 166, height: 760)
    .background(DayflowTheme.dark.sidebarBackground)
    .dayflowTheme(.dark)
}
