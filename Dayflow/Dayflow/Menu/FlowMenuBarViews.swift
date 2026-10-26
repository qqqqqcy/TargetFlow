//
//  FlowMenuBarViews.swift
//  Dayflow
//
//  What the menu bar shows while a Flow session is on: the countdown pill that
//  stands in for the status icon, and the illustrated hero at the top of the
//  menu. Neither appears outside a session.
//

import SwiftUI

/// A piece of artwork cropped the way the design crops it: the image is laid
/// out larger than its box and shifted, and the box clips the rest.
private struct CroppedArt: View {
  let name: String
  let box: CGSize
  let imageSize: CGSize
  let imageOffset: CGSize

  var body: some View {
    Image(name)
      .resizable()
      .interpolation(.high)
      .frame(width: imageSize.width, height: imageSize.height)
      .offset(imageOffset)
      .frame(width: box.width, height: box.height, alignment: .topLeading)
      .clipped()
  }
}

/// The white patch the design puts behind the creature's map.
private struct MapPatch: Shape {
  let points: [CGPoint]
  let size: CGSize

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let sx = rect.width / size.width
    let sy = rect.height / size.height
    for (index, point) in points.enumerated() {
      let scaled = CGPoint(x: point.x * sx, y: point.y * sy)
      if index == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
    }
    path.closeSubpath()
    return path
  }
}

// MARK: - Status item pill

/// Replaces the status icon during a session: the creature's face and the
/// time left (or the time so far, for an always-on session).
struct FlowMenuBarPill: View {
  let time: String?

  var body: some View {
    HStack(spacing: 8) {
      face
      if let time {
        Text(time)
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(Color(red: 1, green: 0.976, blue: 0.949))
          .fixedSize()
      }
    }
    .padding(.leading, 8)
    .padding(.trailing, time == nil ? 8 : 10)
    .frame(height: 21)
    .background(
      LinearGradient(
        stops: [
          .init(color: Color(red: 1, green: 0.58, blue: 0.325).opacity(0.68), location: 0),
          .init(color: Color(red: 0.251, green: 0.157, blue: 0.137).opacity(0.68), location: 0.3),
          .init(color: .black.opacity(0.68), location: 0.65),
          .init(color: .black.opacity(0.68), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)
    )
    .clipShape(Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.3))
  }

  private var face: some View {
    ZStack(alignment: .topLeading) {
      MapPatch(
        points: [
          CGPoint(x: 7.941, y: 0.243), CGPoint(x: 0.967, y: 0), CGPoint(x: 0, y: 1.346),
          CGPoint(x: 0.152, y: 5.397), CGPoint(x: 5.791, y: 5.794), CGPoint(x: 8.367, y: 4.728),
        ],
        size: CGSize(width: 8.367, height: 5.794)
      )
      .fill(.white)
      .frame(width: 8.367, height: 5.794)
      .offset(x: 3.66, y: 8.39)

      CroppedArt(
        name: "FlowMenuCreature",
        box: CGSize(width: 17.47, height: 15.934),
        imageSize: CGSize(width: 51.68, height: 29.2),
        imageOffset: CGSize(width: -12.19, height: -4.77)
      )
      .offset(x: 2.265, y: 1.033)
    }
    .frame(width: 22, height: 18, alignment: .topLeading)
  }
}

// MARK: - Session hero

/// The countdown on the hero. The status bar controller's once-a-second timer
/// runs in the common run loop modes, so it keeps ticking while the menu is open.
@MainActor
final class FlowMenuClock: ObservableObject {
  @Published var label: String?
}

/// The illustrated header at the top of the status menu. The design is drawn
/// at a 160pt wide menu; `scale` brings it up to the width of a real one.
/// Break and End open their prompts in place, so the menu stays open until
/// the user picks a break length or confirms the end.
struct FlowMenuSessionHero: View {
  enum Mode: Equatable {
    case inProgress
    case onBreak
    /// Dayflow's recording is paused, so Flow can't see the screen.
    case dayflowPaused
  }

  enum Control: Equatable {
    case startBreak(minutes: Int)
    case resume
    case end
  }

  /// The designed states: the three in-session ones swap in place.
  private enum Scene {
    case session
    case breakLength
    case confirmEnd
    case onBreak
    case dayflowPaused
  }

  static let scale: CGFloat = 1.45
  static let breakLengths = [5, 10, 15]

  /// The break heroes are drawn 5pt shorter than the in-session ones.
  static func size(for mode: Mode) -> CGSize {
    CGSize(width: 160 * scale, height: (mode == .inProgress ? 95 : 90) * scale)
  }

  let mode: Mode
  @ObservedObject var clock: FlowMenuClock
  let onControl: (Control) -> Void

  @State private var prompt: Scene = .session
  @Environment(\.colorScheme) private var colorScheme

  private var s: CGFloat { Self.scale }

  private var scene: Scene {
    switch mode {
    case .inProgress: return prompt
    case .onBreak: return .onBreak
    case .dayflowPaused: return .dayflowPaused
    }
  }

  var body: some View {
    let size = Self.size(for: mode)
    ZStack(alignment: .topLeading) {
      backdrop(size: size)
      creature
      content
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .clipped()
  }

  // MARK: Backdrop

  private func backdrop(size: CGSize) -> some View {
    let tall = mode == .inProgress
    return ZStack(alignment: .topLeading) {
      CroppedArt(
        name: "FlowMenuEnvironment",
        box: size,
        imageSize: tall
          ? CGSize(width: 436.24 * s, height: 290.7 * s)
          : CGSize(width: 413.05 * s, height: 275.4 * s),
        imageOffset: tall
          ? CGSize(width: -192.15 * s, height: -66.86 * s)
          : CGSize(width: -177.65 * s, height: -63.34 * s))

      LinearGradient(stops: fade, startPoint: .top, endPoint: .bottom)

      streak(streakColors.0, width: 140, degrees: 8, center: CGPoint(x: 57.79, y: 36.64))
      streak(streakColors.1, width: 120, degrees: -6, center: CGPoint(x: 120.82, y: 34.67))

      if scene == .onBreak || scene == .dayflowPaused {
        stars
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    // The design fades to the white of its menu; the real menu is a material
    // that can be dark, so the art fades out into it instead.
    .mask(
      LinearGradient(
        stops: [.init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom))
  }

  private var fade: [Gradient.Stop] {
    let end = colorScheme == .dark ? Color.clear : .white
    func stops(
      _ a: (Double, Double, Double), _ b: (Double, Double, Double), at middle: Double,
      _ c: (Double, Double, Double)
    ) -> [Gradient.Stop] {
      [
        .init(color: rgb(a).opacity(0.94), location: 0),
        .init(color: rgb(b).opacity(0.84), location: middle),
        .init(color: rgb(c).opacity(0.62), location: 0.78),
        .init(color: end, location: 1),
      ]
    }
    switch scene {
    case .session:
      return stops((255, 142, 114), (164, 184, 240), at: 0.35137, (210, 241, 252))
    case .confirmEnd:
      return stops((225, 82, 53), (249, 150, 96), at: 0.42, (251, 192, 154))
    case .breakLength:
      return stops((139, 157, 224), (147, 203, 238), at: 0.42, (216, 255, 244))
    case .onBreak, .dayflowPaused:
      return stops((142, 137, 166), (179, 173, 200), at: 0.42, (236, 232, 243))
    }
  }

  private var streakColors: (Color, Color) {
    switch scene {
    case .session: return (rgb((255, 211, 194)).opacity(0.45), rgb((255, 179, 200)).opacity(0.4))
    case .confirmEnd: return (rgb((255, 154, 90)).opacity(0.45), rgb((255, 107, 74)).opacity(0.4))
    case .breakLength:
      return (rgb((207, 227, 255)).opacity(0.45), rgb((226, 211, 255)).opacity(0.4))
    case .onBreak, .dayflowPaused:
      return (rgb((214, 208, 234)).opacity(0.45), rgb((194, 204, 230)).opacity(0.4))
    }
  }

  /// A soft blurred ellipse of light across the sky.
  private func streak(_ color: Color, width: CGFloat, degrees: Double, center: CGPoint)
    -> some View
  {
    Ellipse()
      .fill(color)
      .frame(width: width * s, height: 22 * s)
      .blur(radius: 7 * s)
      .rotationEffect(.degrees(degrees))
      .position(x: center.x * s, y: center.y * s)
  }

  private var stars: some View {
    let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
      (20, 8, 1, 0.8), (46, 22, 0.8, 0.6), (70, 6, 1.2, 0.9),
      (96, 14, 0.8, 0.6), (122, 8, 1, 0.8), (146, 20, 0.8, 0.5),
    ]
    return ForEach(stars.indices, id: \.self) { index in
      let star = stars[index]
      Circle()
        .fill(.white.opacity(star.opacity))
        .frame(width: star.size * s, height: star.size * s)
        .offset(x: star.x * s, y: star.y * s)
    }
  }

  // MARK: Creature

  @ViewBuilder
  private var creature: some View {
    switch scene {
    case .session:
      art(
        "FlowMenuCreature", at: CGPoint(x: 111.98, y: 52.25),
        box: CGSize(width: 52.618, height: 39.34),
        image: CGSize(width: 89.319, height: 50.473), offset: CGSize(width: -14.433, height: -8.246)
      )
    case .confirmEnd:
      art(
        "FlowMenuCreatureMeh", at: CGPoint(x: 115.2, y: 52.81),
        box: CGSize(width: 51.441, height: 40.124),
        image: CGSize(width: 66.472, height: 50.307), offset: CGSize(width: -6.672, height: -4.791))
    case .breakLength:
      art(
        "FlowMenuCreatureTea", at: CGPoint(x: 114, y: 52.72), box: CGSize(width: 52, height: 40),
        image: CGSize(width: 92.102, height: 51.872), offset: CGSize(width: -17.046, height: -9.736)
      )
    case .onBreak, .dayflowPaused:
      art(
        "FlowMenuCreatureSleep", at: CGPoint(x: 101.4, y: 55.4),
        box: CGSize(width: 53.474, height: 32.409),
        image: CGSize(width: 66.677, height: 50.727), offset: CGSize(width: -6.802, height: -8.05))
    }
  }

  private func art(
    _ name: String, at origin: CGPoint, box: CGSize, image: CGSize, offset: CGSize
  ) -> some View {
    CroppedArt(
      name: name,
      box: CGSize(width: box.width * s, height: box.height * s),
      imageSize: CGSize(width: image.width * s, height: image.height * s),
      imageOffset: CGSize(width: offset.width * s, height: offset.height * s)
    )
    .offset(x: origin.x * s, y: origin.y * s)
  }

  // MARK: Copy and controls

  @ViewBuilder
  private var content: some View {
    switch scene {
    case .session:
      VStack(alignment: .leading, spacing: 0) {
        Text("Flow session in progress")
          .font(.system(size: 7 * s, weight: .medium))
          .tracking(0.56 * s)
          .foregroundStyle(.white.opacity(0.72))
        Text(verbatim: clock.label ?? "")
          .font(.system(size: 22 * s, weight: .bold))
          .tracking(-0.22 * s)
          .foregroundStyle(.white)
          .frame(height: 26 * s)
      }
      .fixedSize()
      .offset(x: 11 * s, y: 10 * s)

      actions {
        GlassPill(icon: "FlowMenuCoffee", title: String(localized: "Break"), scale: s) {
          prompt = .breakLength
        }
        GlassPill(icon: "FlowMenuStop", title: String(localized: "End"), scale: s) {
          prompt = .confirmEnd
        }
      }

    case .confirmEnd:
      VStack(alignment: .leading, spacing: 3 * s) {
        title(String(localized: "Ending early?"))
        Text("You’ll earn fewer steps if you end now.")
          .font(.system(size: 7 * s, weight: .medium))
          .lineSpacing(0.65 * s)
          .foregroundStyle(.white.opacity(0.88))
          // 84pt in the design; native text sets a touch wider, so this keeps
          // the design's line break after "if".
          .frame(width: 86 * s, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .offset(x: 11 * s, y: 10 * s)

      actions {
        GlassPill(
          icon: "FlowMenuKeepGoing", iconSize: 9, title: String(localized: "Keep going"), scale: s
        ) { prompt = .session }
        GlassPill(icon: "FlowMenuStop", title: String(localized: "End"), scale: s) {
          onControl(.end)
        }
      }

    case .breakLength:
      Text("How long will your break be?")
        .font(.system(size: 9 * s, weight: .semibold))
        .foregroundStyle(.white)
        .fixedSize()
        .offset(x: 10 * s, y: 10 * s)

      HStack(spacing: 4 * s) {
        ForEach(Self.breakLengths, id: \.self) { minutes in
          BreakLengthChip(minutes: minutes, scale: s) { onControl(.startBreak(minutes: minutes)) }
        }
      }
      .offset(x: 10 * s, y: 27.27 * s)

      actions {
        GlassPill(
          icon: "FlowMenuKeepGoing", iconSize: 9, title: String(localized: "Keep going"), scale: s
        ) { prompt = .session }
      }

    case .onBreak:
      VStack(alignment: .leading, spacing: 1 * s) {
        title(String(localized: "Taking a break"))
        if let time = clock.label {
          subtitle(String(localized: "\(time) until your break ends."))
        }
      }
      .offset(x: 11 * s, y: 10 * s)

      actions {
        GlassPill(icon: "FlowMenuPlay", title: String(localized: "Resume"), scale: s) {
          onControl(.resume)
        }
      }

    case .dayflowPaused:
      VStack(alignment: .leading, spacing: 1 * s) {
        title(String(localized: "Target Flow is paused."))
        subtitle(String(localized: "Resume Target Flow to continue with the current session."))
          .frame(width: 96 * s, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .offset(x: 11 * s, y: 10 * s)
    }
  }

  private func title(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 15 * s, weight: .bold))
      .foregroundStyle(.white)
      .frame(height: 18 * s)
      .fixedSize()
  }

  private func subtitle(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 7 * s, weight: .medium))
      .foregroundStyle(.white.opacity(0.75))
  }

  private func actions<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
    HStack(spacing: 4 * s) { buttons() }
      .offset(x: 10 * s, y: 61.87 * s)
  }

  private func rgb(_ value: (Double, Double, Double)) -> Color {
    Color(red: value.0 / 255, green: value.1 / 255, blue: value.2 / 255)
  }
}

/// The frosted glass behind the hero's buttons.
private struct FrostedGlass<GlassShape: InsettableShape>: View {
  let shape: GlassShape
  let hovering: Bool
  let scale: CGFloat

  var body: some View {
    shape
      .fill(Color(red: 43 / 255, green: 44 / 255, blue: 52 / 255).opacity(0.3))
      .overlay(
        shape.fill(
          LinearGradient(
            stops: [
              .init(color: .white.opacity(0.3), location: 0),
              .init(color: .white.opacity(0.12), location: 0.5),
              .init(
                color: Color(red: 226 / 255, green: 242 / 255, blue: 252 / 255).opacity(0.3),
                location: 1),
            ],
            startPoint: .top, endPoint: .bottom))
      )
      .overlay(shape.fill(.white.opacity(hovering ? 0.18 : 0)))
      .overlay(shape.strokeBorder(.white.opacity(0.66), lineWidth: 0.55 * scale))
      .shadow(
        color: Color(red: 227 / 255, green: 244 / 255, blue: 1).opacity(0.3), radius: 1 * scale)
  }
}

/// A pill-shaped glass button with an icon and a label.
private struct GlassPill: View {
  let icon: String
  var iconSize: CGFloat = 8
  let title: String
  let scale: CGFloat
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 3 * scale) {
        Image(icon)
          .resizable()
          .frame(width: iconSize * scale, height: iconSize * scale)
        Text(title)
          .font(.system(size: 7.5 * scale, weight: .semibold))
          .foregroundStyle(.white)
          .fixedSize()
      }
      .padding(.leading, 5.55 * scale)
      .padding(.trailing, 7.55 * scale)
      .frame(height: 20.1 * scale)
      .background(FrostedGlass(shape: Capsule(), hovering: hovering, scale: scale))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering = $0 }
  }
}

/// One of the round break length buttons.
private struct BreakLengthChip: View {
  let minutes: Int
  let scale: CGFloat
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: -3 * scale) {
        Text(verbatim: "\(minutes)")
          .font(.system(size: 12 * scale, weight: .bold))
          .frame(height: 14 * scale)
        Text("min")
          .font(.system(size: 5.5 * scale, weight: .semibold))
          .foregroundStyle(.white.opacity(0.75))
      }
      .foregroundStyle(.white)
      .frame(width: 30 * scale, height: 30 * scale)
      .background(FrostedGlass(shape: Circle(), hovering: hovering, scale: scale))
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering = $0 }
    .accessibilityLabel(String(localized: "\(minutes) minute break"))
  }
}
