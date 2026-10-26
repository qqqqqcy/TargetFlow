//
//  FlowEarlyBirdCard.swift
//  Dayflow
//
//  The card that floats under the menu bar for the first hour Dayflow is on
//  each day: start a Flow session before the countdown runs out and it earns
//  double points.
//

import SwiftUI

struct FlowEarlyBirdCard: View {
  static let size = CGSize(width: 298, height: 146)

  /// When the hour runs out.
  let deadline: Date
  let onStart: () -> Void
  let onClose: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color(red: 1, green: 0.976, blue: 0.961)

      // The design blurs the scenery behind its tint.
      Image("FlowEarlyBirdBackground")
        .resizable()
        .interpolation(.high)
        .frame(width: 499.15, height: 332.79)
        .offset(x: -201.15, y: -97.34 - 18.66)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .blur(radius: 10.8)
        .clipped()

      RadialGradient(
        stops: [
          .init(color: Color(red: 1, green: 0.949, blue: 0.722).opacity(0.64), location: 0),
          .init(color: Color(red: 1, green: 0.733, blue: 0.627).opacity(0.4), location: 0.366),
          .init(
            color: Color(red: 0.761, green: 0.604, blue: 0.816).opacity(0.485), location: 0.605),
          .init(color: Color(red: 0.525, green: 0.471, blue: 1).opacity(0.57), location: 0.844),
          .init(color: Color(red: 0.396, green: 0.518, blue: 1).opacity(0.57), location: 1),
        ],
        center: UnitPoint(x: 251.5 / Self.size.width, y: 160 / Self.size.height),
        startRadius: 0, endRadius: 270)

      LinearGradient(
        stops: [
          .init(color: Color(red: 0.094, green: 0.157, blue: 0.239).opacity(0.19), location: 0),
          .init(color: .clear, location: 0.74),
        ],
        startPoint: .leading, endPoint: .trailing)

      // The white of the creature's map, which the cut-out leaves see-through.
      Rectangle()
        .fill(.white)
        .frame(width: 50.3, height: 37.4)
        .offset(x: 222.75, y: 79.3)

      Image("FlowEarlyBirdCreature")
        .resizable()
        .interpolation(.high)
        .frame(width: 231.5, height: 130.72)
        .offset(x: -31.42)
        .frame(width: 147.44, height: 130.72, alignment: .topLeading)
        .clipped()
        .offset(x: 204.04, y: 38)

      copy
        .offset(x: 16, y: 12)

      Button(action: onClose) {
        Image("FlowEarlyBirdClose")
          .resizable()
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .help(String(localized: "Close"))
      .accessibilityLabel(String(localized: "Close"))
      .offset(x: 265.76, y: 7.5)
    }
    .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: 6.4, x: 0, y: 2)
  }

  private var copy: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Start a session within the hour you opened Target Flow to earn 2X the points.")
        .font(.custom("Figtree", size: 13))
        // The design sets the lines solid (13pt on 13pt).
        .lineSpacing(-3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: 39)

      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(Self.countdown(from: context.date, to: deadline))
          .font(.system(size: 34, weight: .semibold, design: .monospaced))
          .fixedSize()
          .frame(height: 34)
      }

      Button(action: onStart) {
        Text("Start session")
          .font(.custom("Figtree", size: 13).weight(.medium))
          .padding(.horizontal, 18)
          .padding(.vertical, 8)
          .background(
            LinearGradient(
              colors: [
                Color(red: 1, green: 0.714, blue: 0.557).opacity(0.8),
                Color(red: 1, green: 0.612, blue: 0.416).opacity(0.8),
              ],
              startPoint: .top, endPoint: .bottom)
          )
          .clipShape(Capsule())
          .overlay(
            Capsule().strokeBorder(Color(red: 0.957, green: 0.784, blue: 0.694), lineWidth: 0.75)
          )
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
    .foregroundStyle(.white)
    .frame(width: 188, alignment: .leading)
  }

  static func countdown(from now: Date, to deadline: Date) -> String {
    let left = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    return String(format: "%02d:%02d", left / 60, left % 60)
  }
}
